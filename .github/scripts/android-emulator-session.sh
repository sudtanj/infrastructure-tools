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
