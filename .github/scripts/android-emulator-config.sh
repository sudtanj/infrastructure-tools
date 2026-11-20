#!/usr/bin/env bash
# Shrinks the AVD's screen before android-emulator-runner launches it. With no
# GPU every frame is drawn on the CPU, and Pixel 6's 1080x2400 is 2.8x the
# pixels of 720x1280; at 320 dpi it is still a 360dp-wide phone. Runs every
# time, so a restored AVD gets it too.
set -euo pipefail

avd="${ANDROID_AVD_HOME:-$HOME/.android/avd}/session.avd"
cfg="$avd/config.ini"
sed -i -E '/^(hw\.lcd\.(width|height|density)|hw\.ramSize|disk\.dataPartition\.size|hw\.sdCard(\.path)?|showDeviceFrame)=/d' "$cfg"
# A second disk, adopted in Android as internal storage, for apps that need
# more room than the 8 GB data disk has left (TikTok showed white pages when
# it had too little space to download them). The data disk itself does not
# grow on a restored AVD: Android encrypts it, so the emulator cannot resize
# it. Sparse, so the saved state only holds what is written to it.
[ -e "$avd/extra.img" ] || truncate -s 8G "$avd/extra.img"
# The AVD is created once and restored after that, so the RAM size is set here
# too, not only by `ram-size`. With 4 GB the guest swapped constantly once an
# ARM app ran under translation.
cat >> "$cfg" <<EOF
hw.ramSize=6144
disk.dataPartition.size=16G
hw.sdCard=yes
hw.sdCard.path=$avd/extra.img
hw.lcd.width=720
hw.lcd.height=1280
hw.lcd.density=320
showDeviceFrame=no
EOF

# Save state skips runs that fail before this point (the AVD is as restored).
touch /tmp/emulator-launched
