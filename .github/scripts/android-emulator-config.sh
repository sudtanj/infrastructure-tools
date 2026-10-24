#!/usr/bin/env bash
# Shrinks the AVD's screen before android-emulator-runner launches it. With no
# GPU every frame is drawn on the CPU, and Pixel 6's 1080x2400 is 2.8x the
# pixels of 720x1280; at 320 dpi it is still a 360dp-wide phone. Runs every
# time, so a restored AVD gets it too.
set -euo pipefail

cfg="${ANDROID_AVD_HOME:-$HOME/.android/avd}/session.avd/config.ini"
sed -i -E '/^(hw\.lcd\.(width|height|density)|hw\.ramSize|showDeviceFrame)=/d' "$cfg"
# The AVD is created once and restored after that, so the RAM size is set here
# too, not only by `ram-size`. With 4 GB the guest swapped constantly once an
# ARM app ran under translation.
cat >> "$cfg" <<'EOF'
hw.ramSize=6144
hw.lcd.width=720
hw.lcd.height=1280
hw.lcd.density=320
showDeviceFrame=no
EOF
grep -E '^(hw\.lcd\.|hw\.ramSize|hw\.cpu\.ncore)' "$cfg"

# Save state skips runs that fail before this point (the AVD is as restored).
touch /tmp/emulator-launched
