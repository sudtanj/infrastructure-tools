#!/usr/bin/env bash
# Keeps the emulator up for remote use over Tailscale until someone drops the
# stop file on the device, or MAX_MINUTES passes. Runs inside
# android-emulator-runner's `script`, which has already waited for boot.
set -euo pipefail

# Leave room under the 360 minute job limit to pack and upload the state.
max="${MAX_MINUTES:-120}"
if [ "$max" -gt 320 ]; then max=320; fi

# Approved adb clients are kept in the saved AVD; without this Android drops
# any key unused for 7 days and the VNC approval is needed again.
adb shell settings put global adb_allowed_connection_time 0

# Back/Home/Recents buttons instead of swipe gestures, which are hard to do
# with a VNC mouse or a script.
adb shell cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.threebutton

# Fewer processes competing with the apps for memory and CPU: these Google
# apps run in the background and took about 1 GB of the guest's RAM. Kept in
# the saved AVD; repeating it is harmless. Not Play services, the Play Store,
# Chrome, WebView or the keyboard, which apps and VNC typing rely on.
enabled="$(adb shell pm list packages -e | tr -d '\r')"
for pkg in com.google.android.googlequicksearchbox com.google.android.as \
  com.google.android.apps.messaging com.google.android.youtube \
  com.google.android.apps.youtube.music com.google.android.apps.photos \
  com.google.android.apps.maps com.google.android.gm com.google.android.apps.docs \
  com.google.android.calendar com.google.android.apps.wellbeing \
  com.google.android.apps.safetyhub com.google.android.tts \
  com.google.android.projection.gearhead com.google.android.apps.restore; do
  if grep -qx "package:$pkg" <<<"$enabled"; then
    adb shell pm disable-user --user 0 "$pkg" >/dev/null && echo "Disabled $pkg." || true
  fi
done
# No Doze and no screen-off: either can pause what is running.
adb shell settings put global stay_on_while_plugged_in 7 || true
adb shell dumpsys deviceidle disable >/dev/null || true

# If the runner runs out of memory, the kernel kills something other than the
# emulator or the display it draws on.
for pid in $(pgrep -f 'qemu-system-x86_64|Xvfb :99'); do
  echo -1000 | sudo tee "/proc/$pid/oom_score_adj" >/dev/null || true
done

# Full screen over VNC: the display is the device's size, so move the phone
# window to fill it and hide the side toolbar and any other emulator windows.
# Best effort; a failure here only leaves the default layout.
fill_screen() {
  local pid wins main geom w h
  pid="$(pgrep -f qemu-system-x86_64 | head -1)" && [ -n "$pid" ] || return 1
  wins="$(xdotool search --onlyvisible --pid "$pid" 2>/dev/null)" || return 1
  read -r w h < <(xdpyinfo | awk '/dimensions:/ { split($2, d, "x"); print d[1], d[2] }')
  # The phone screen is the largest window.
  main="$(for id in $wins; do
    geom="$(xdotool getwindowgeometry "$id" | awk '/Geometry:/ { print $2 }')"
    echo "$(( ${geom%x*} * ${geom#*x} )) $id"
  done | sort -n | tail -1 | cut -d' ' -f2)"
  for id in $wins; do
    [ "$id" = "$main" ] || xdotool windowunmap "$id" || true
  done
  xdotool windowmove "$main" 0 0 windowsize "$main" "$w" "$h"
  xdotool getwindowgeometry "$main"
}
fill_screen || echo "::warning::Could not make the emulator window full screen."

# Host memory and the emulator's resident size, for telling an OOM kill from
# a crash afterwards.
log_memory() {
  local pid rss
  pid="$(pgrep -f qemu-system-x86_64 | head -1)" || true
  rss="$( [ -n "$pid" ] && ps -o rss= -p "$pid" | awk '{ printf "%d", $1 / 1024 }' )" || true
  free -m | awk -v rss="${rss:-?}" '/^Mem:/ { printf "memory: host used %d MiB, available %d MiB; emulator RSS %s MiB\n", $3, $7, rss }'
}

# qemu has died with no crash dump, no OOM kill and no output. Record, in the
# kernel's own trace buffer, every fatal signal and every process exit with its
# code, so the next death says who ended it and how. Best effort.
tracing=/sys/kernel/tracing
[ -d "$tracing/events" ] || tracing=/sys/kernel/debug/tracing
sudo sh -c "
  echo 1 > $tracing/options/record-tgid
  echo 'sig == 1 || sig == 2 || sig == 4 || sig == 6 || sig == 7 || sig == 8 || sig == 9 || sig == 11 || sig == 15' \
    > $tracing/events/signal/signal_generate/filter
  echo 1 > $tracing/events/signal/signal_generate/enable
  echo 1 > $tracing/events/syscalls/sys_enter_exit_group/enable
  echo 1 > $tracing/tracing_on
" 2>/dev/null || echo "::warning::Could not enable kernel tracing."
qemu_pid="$(pgrep -f qemu-system-x86_64 | head -1)" || true

# qemu can die without a word (the OOM killer, a crash in its host video
# decoder); adb then only says "offline" and the stop file never comes. End
# the run so Save state runs.
emulator_died() {
  echo "::error title=Emulator exited::qemu-system-x86_64 is gone; ending the session."
  sudo dmesg -T | grep -iE 'out of memory|oom-kill|killed process|segfault|qemu' | tail -20 || true
  log_memory
  pgrep -a Xvfb >/dev/null || echo "Xvfb is gone too."
  echo "Kernel trace of qemu's end (pid ${qemu_pid:-?}; $(sudo grep -vc "^#" "$tracing/trace" 2>/dev/null || echo 0) events recorded):"
  sudo cat "$tracing/trace" 2>/dev/null \
    | grep -E "signal_generate|\\( *${qemu_pid:-x}\\)" | tail -30 || true
  ls -R /tmp/android-runner 2>/dev/null | tail -20 || true
  # The emulator's crash handler writes a minidump; none means qemu was
  # killed or exited by itself.
  local dumps
  dumps="$(find /tmp/android-runner ~/.android -name '*.dmp' -newer /tmp/emulator-launched 2>/dev/null || true)"
  if [ -n "$dumps" ]; then
    # shellcheck disable=SC2086
    python3 .github/scripts/minidump-summary.py $dumps || true
  else
    echo "No crash dump was written."
  fi
  exit 1
}

# Scheduled runs: launch EraSpace's rocket, play PineDrama until its coin
# timer is gone or AUTOPLAY_MINUTES pass, then end the session so it saves.
if [ "${AUTOPLAY:-false}" = true ]; then
  minutes="${AUTOPLAY_MINUTES:-30}"
  echo "Emulator ready. Playing PineDrama until the coin is gone (limit ${minutes} minutes)."
  log_memory
  # EraSpace's daily rocket launch first: a few minutes at most.
  DEVICE=emulator-5554 timeout 10m node .github/scripts/eraspace/eraspace.ts \
    || echo "::warning::The EraSpace script ended with an error; going on."
  # It lowers the screen density while it plays; PineDrama's taps assume 320.
  adb shell wm density reset || true
  # The 05:00 run is for the rocket alone.
  if [ "${PLAY_PINEDRAMA:-true}" = true ]; then
    DEVICE=emulator-5554 MAX_MINUTES="$minutes" \
      timeout "$((minutes + 15))m" node .github/scripts/pinedrama/pinedrama.ts \
      || echo "::warning::The PineDrama script ended with an error; saving anyway."
  fi
  pgrep -f qemu-system-x86_64 >/dev/null || emulator_died
  log_memory
  max=0
else
  echo "Emulator ready. Waiting for the stop file (limit ${max} minutes)."
  log_memory
fi
deadline=$((SECONDS + max * 60))
next_memory_log=$((SECONDS + 300))
while [ "$SECONDS" -lt "$deadline" ]; do
  pgrep -f qemu-system-x86_64 >/dev/null || emulator_died
  if adb shell test -e /data/local/tmp/stop-session 2>/dev/null; then
    echo "Stop file found."
    break
  fi
  if [ "$SECONDS" -ge "$next_memory_log" ]; then
    log_memory
    next_memory_log=$((SECONDS + 300))
  fi
  sleep 15
done

adb shell rm -f /data/local/tmp/stop-session
# Flush the guest's page cache so the saved userdata image is consistent.
adb shell sync
