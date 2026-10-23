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

echo "Emulator ready. Waiting for the stop file (limit ${max} minutes)."
deadline=$((SECONDS + max * 60))
while [ "$SECONDS" -lt "$deadline" ]; do
  if adb shell test -e /data/local/tmp/stop-session 2>/dev/null; then
    echo "Stop file found."
    break
  fi
  sleep 15
done

adb shell rm -f /data/local/tmp/stop-session
# Flush the guest's page cache so the saved userdata image is consistent.
adb shell sync
