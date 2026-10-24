#!/usr/bin/env bash
# Shrinks the AVD's screen before android-emulator-runner launches it. With no
# GPU every frame is drawn on the CPU, and Pixel 6's 1080x2400 is 2.8x the
# pixels of 720x1280; at 320 dpi it is still a 360dp-wide phone. Runs every
# time, so a restored AVD gets it too.
set -euo pipefail

cfg="${ANDROID_AVD_HOME:-$HOME/.android/avd}/session.avd/config.ini"
sed -i -E '/^(hw\.lcd\.(width|height|density)|showDeviceFrame)=/d' "$cfg"
cat >> "$cfg" <<'EOF'
hw.lcd.width=720
hw.lcd.height=1280
hw.lcd.density=320
showDeviceFrame=no
EOF
grep -E '^(hw\.lcd\.|hw\.ramSize|hw\.cpu\.ncore)' "$cfg"

# Save state keeps the snapshot only if it was written after this.
touch /tmp/emulator-launched
