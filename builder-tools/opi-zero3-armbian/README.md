# Orange Pi Zero 3: minimal, locked-down Armbian Docker host

Part of the builder-tools monorepo. Builds an SD card image with the
[Armbian build framework](https://github.com/armbian/build): Armbian's minimal CLI flavour of
Debian trixie with the `current` kernel, cut down to a box that only runs Docker containers
(the `bash-scripts/init-*.sh` deployments) and hardened.

## What the image is

- **Base:** `BOARD=orangepizero3 BRANCH=current RELEASE=trixie BUILD_MINIMAL=yes`
  (systemd-networkd + netplan, zram, `/var/log` in RAM). Change it in [`variables`](variables).
- **Docker CE** from download.docker.com, engine only (no compose/buildx plugins). `daemon.json`
  uses the `local` log driver at 2 × 5 MB per container (SD card), `live-restore`, no userland
  proxy and `no-new-privileges` for every container.
- **No default login.** Armbian's known root password, root autologin on the consoles and the
  interactive first-login wizard are removed, and root is locked. The only account is the one
  you provision (see below), which uses sudo with a password and is not in the `docker` group.
- **sshd:** no root login, keys only from the internet, passwords only from private ranges and
  the tailnet (`100.64.0.0/10`), `AllowUsers` = the provisioned user, no forwarding of any kind,
  3 auth tries. Host keys are regenerated on first boot.
- **Firewall** (`/etc/opi/nftables.conf`, loaded by `opi-firewall.service` into its own
  `inet opi_host` table, so Docker's and Tailscale's rules are never flushed). Input is allowed from `tailscale0`, the Docker bridges, the LAN
  (private ranges, link-local), ICMP, DHCP and UDP 41641 (Tailscale direct). Everything else is
  dropped, notably the public IPv6 address the router hands out. Published container ports and
  the exit node go through forward, which Docker and Tailscale manage as before. If you change
  `OPI_TS_PORT`, change 41641 here too.
- **Kernel/sysctl:** kptr/dmesg restricted, unprivileged BPF off, no ICMP redirects or source
  routing, protected links/FIFOs. Bluetooth and the dccp/sctp/rds/tipc protocols are blocked.
  IP forwarding and rp_filter are left to Docker and `opi-init-tailscale-docker.sh`.
- **Small:** no docs, man pages or translations (a dpkg filter, so upgrades stay small too;
  licenses are kept), no translated package descriptions, apt lists kept compressed.
  Firmware for hardware an H618 board can't have (Qualcomm SoCs, PCIe-only Wi-Fi, Rockchip
  modules: about 400 MB of Armbian's 434 MB firmware package) is filtered the same way. The
  board's UWE5622 Wi-Fi and USB Wi-Fi/Bluetooth dongle firmware stay.
  Removed from Armbian's minimal set: Python and Perl (nothing on a Docker host needs them),
  armbian-config, rsyslog (journald, capped at 24 MB), ALSA, man-db, bluez, btrfs-progs,
  dosfstools, wireguard-tools, figlet/toilet and a few others if present. Wi-Fi config in
  `/etc/netplan` still works: netplan's generator is C, only its `netplan` command is Python.
  The build fails rather than let a removal take a dependent package with it. Avahi, Bluetooth
  (including Armbian's `aw859a-bluetooth`) and ModemManager are masked, and so is
  `nftables.service` (its `/etc/nftables.conf` starts with `flush ruleset`).
- **Updates:** `opi-security-upgrade.timer` installs Debian security updates (`trixie-security`)
  daily and nothing else: apt sees only the security archive, from its own source list and index,
  and `apt-get upgrade` never removes or adds a package (a fix that needs a newer dependency from
  outside the security archive waits for a manual `apt upgrade`). It never reboots. `sudo
  opi-security-upgrade --dry-run` shows what it would do. Docker and Armbian packages (kernel,
  U-Boot, firmware): `apt upgrade` by hand, or flash a newer image.
- **Upgrade-safe:** the image only adds files and drop-ins (`sshd_config.d/`, `sysctl.d/`,
  `apt.conf.d/`, its own units). No package-owned file is edited, so Debian, Armbian and Docker
  upgrades never stop at a conffile prompt, and an upgrade can't overwrite the lockdown.
- **`sudo opi-selfcheck`** on the board checks all of the above (accounts, effective sshd config
  per source address, pristine conffiles, services, firewall, sysctl, Docker). The build and the
  tests run the same script.

## Wi-Fi driver

The Zero 3's onboard Wi-Fi/Bluetooth chip is a Unisoc UWE5622 on SDIO. Every build produces
two images that differ only in its driver:

| Image | Driver | Status |
|---|---|---|
| `Armbian-unofficial_..._minimal.img.xz` | Armbian's in-tree driver (modules `uwe5622_bsp_sdio`, `sprdwl_ng`, `sprdbt_tty` in `/lib/modules/<ver>/kernel/`) | default, in daily use on Armbian |
| `Armbian-unofficial_..._minimal-uwe5622-mainline.img.xz` | [uwe5622-mainline](https://github.com/sudtanj/uwe5622-mainline) at `UWE5622_COMMIT`, same module names, in `/lib/modules/<ver>/updates/uwe5622/` | candidate, not yet tested on a board |

- **How the mainline image is made** ([`uwe5622/`](uwe5622/)): after the Armbian build, the
  `build-uwe5622` job installs Armbian's own `linux-headers` package of the image's kernel on the
  arm64 runner (its postinst restores the kernel's build-time config), builds the three modules
  natively ([`build-modules.sh`](uwe5622/build-modules.sh): modpost resolves every symbol against
  the kernel's `Module.symvers`, and the vermagic must be the image's kernel release), copies them
  into `updates/uwe5622/` of the image and runs `depmod` for that kernel inside it
  ([`make-image.sh`](uwe5622/make-image.sh)). `updates/` takes precedence over `kernel/` for
  modules of the same name. Nothing else differs; the Bluetooth blacklist applies to both.
  `/lib/modules/<ver>/updates/uwe5622/SOURCE` records the driver commit. The modules, the build
  log and the kernel's `Module.symvers` are also uploaded as `uwe5622-mainline-modules-<ver>`.
- **Switching the default:** `UWE5622_DRIVER` in [`variables`](variables) (`armbian` or
  `mainline`) picks which of the two images gets the plain name; the other one gets a
  `-uwe5622-mainline` or `-uwe5622-armbian` suffix. Both are always built and tested. Keep
  `armbian` until the mainline image has been confirmed on a board.
- **Fallback on kernel upgrades:** the modules are only valid for the kernel they were built
  for, and `updates/` is per kernel version. After `apt upgrade` installs a new Armbian kernel,
  `/lib/modules/<new>/updates/` doesn't exist, so the board boots with Armbian's in-tree driver
  automatically (flash a newer mainline image to get the mainline driver back). If Armbian ever
  rebuilt a kernel package without changing its version, the old modules would still be picked
  up; the kernel then refuses them if the symbol versions changed (`dmesg`: `disagrees about
  version of symbol`), and the rollback below applies.
- **Weekly update:** the scheduled run also checks the driver's `main`. When it differs from
  `UWE5622_COMMIT`, that commit is built into the mainline image as a candidate and the pin is
  only committed when `inspect-uwe5622` and `simulate-uwe5622` pass (the same gate as Armbian's).
- **What CI proves:** `inspect-uwe5622` checks the modules are in `updates/`, their vermagic,
  that every symbol they import resolves (`depmod -e` against the kernel's `System.map` or
  `Module.symvers`), that `modprobe sprdwl_ng` resolves to `updates/`, that the firmware the
  driver loads is there (`uwe5622/wcnmodem.bin`, `wifi_2355b001_1ant.ini`), that the Bluetooth
  blacklist is unchanged and still makes `modprobe sprdbt_tty` a no-op, that the initrd carries no
  copy of the driver, and `opi-selfcheck --image`. `simulate-uwe5622` builds the same commit
  against the simulation's Debian kernel and loads and unloads the modules ten times with no chip
  present: the probe must fail cleanly, everything must unload, the kernel log must show no
  oops, WARN or BUG and no new taint, and afterwards selfcheck, Docker, Dozzle and the memory
  check must still pass. This proves the integration and the driver's robustness when the chip
  doesn't answer. It does **not** prove that Wi-Fi works: QEMU has no UWE5622 and no H618 SDIO
  controller, so firmware upload, scanning and association are only tested on a board.

### Testing on the board

Flash the `-uwe5622-mainline` image (with a serial console on the 3-pin UART header if you can:
a crash in a driver takes the network with it), provision it as usual, then:

```bash
cat /lib/modules/$(uname -r)/updates/uwe5622/SOURCE      # which driver commit
modinfo -n sprdwl_ng                                     # .../updates/uwe5622/sprdwl_ng.ko
sudo dmesg | grep -iE 'wcn|sprd|marlin|sdio|mmc1|unisoc' | tail -n 50
iw dev                                                   # expect wlan0
sudo ip link set wlan0 up && sudo iw wlan0 scan | grep -E 'SSID|signal' | head
```

Then connect through `/etc/netplan` (or `WIFI_SSID` / `WIFI_PASSWORD` in the provisioning file) and keep it
running for a while (`ping` across the tailnet, a reboot, a Docker pull over Wi-Fi). If that all
works, set `UWE5622_DRIVER="mainline"`.

**Rollback** to Armbian's driver on a running board, without reflashing:

```bash
sudo rm -r /lib/modules/$(uname -r)/updates/uwe5622
sudo depmod -a
sudo reboot
```

## Build

[`builder-tools-opi-zero3-armbian.yml`](../../.github/workflows/builder-tools-opi-zero3-armbian.yml)
runs on a native arm64 runner:

- **Upstream updates, gated:** every Monday (and on a manual run) it looks for new fixes on the
  pinned Armbian release branch (`ARMBIAN_BRANCH` in [`variables`](variables)). When its head
  differs from `ARMBIAN_COMMIT`, that commit is built and put through all the tests below as a
  candidate. Only when everything passes does the `promote` job commit the new pin to `main`.
  A breaking upstream change fails the run, and `main` stays on the last good pin.
- **New Armbian releases are opt-in:** a newer release branch (`vYY.MM`, usually a new kernel
  line and U-Boot) only shows up as a notice on the run. Run the workflow with `new_release` to
  build and test it; it is promoted the same way when everything passes.
- A push touching this folder, `bash-scripts/opi-init-tailscale-docker.sh`,
  `bash-scripts/init-dozzle.sh` or the workflow builds and tests the pinned commit. Pull requests
  run the unit stage only.
- The image (`Armbian-unofficial_*_Orangepizero3_trixie_current_*_minimal.img.xz` + `.sha`)
  is uploaded as an artifact kept for 14 days. It contains no secrets, so it is safe as a public
  artifact.

The customization lives in [`userpatches/customize-image.sh`](userpatches/customize-image.sh)
(runs in the image chroot) and the files in [`userpatches/overlay/`](userpatches/overlay/).
Armbian changes the image after that script (it installs armbian-config, which brings Python
back, and copies in uncompressed apt lists), so the [`opi-image` extension](userpatches/extensions/opi-image.sh)
undoes both later in the build: it purges every package that was not installed when the script
finished. The workflow copies `bash-scripts/opi-init-tailscale-docker.sh` into the overlay at build time.

## Tests

| Job | What | Where |
|---|---|---|
| `unit` | shellcheck, plus [bats](tests/unit/) tests of `opi-provision`: the file is parsed and never executed; validation; user, sudo and docker group; keys; host name; time zone; Wi-Fi YAML escaping; Tailscale gets only its own variables; no secret in the log; failure handling. The same suite tests the configs against the real openssh, nftables and apt of the image's Debian release: effective sshd settings per source address, `Match` not leaking into later drop-ins, nft reload keeping other tables, `opi-security-upgrade` using only the security archive (a dry run, then a real upgrade of the container) | Debian container, [`tests/unit/run.sh`](tests/unit/run.sh) |
| `unit` | [Firewall with real packets](tests/firewall-netns.sh), using network namespaces for the board, a LAN/internet client and a tailnet peer. LAN v4/v6 and `tailscale0` get in. Public v4/v6, and CGNAT addresses outside `tailscale0`, are dropped. Replies, ICMP and reloads work | runner, root |
| `inspect` | [The built image](tests/image-inspect.sh): U-Boot SPL (`eGON.BT0`) at 8 KiB for the H618 boot ROM, boot script, Zero 3 device tree, kernel, initrd and `rootdev` UUID. Also: the board kernel's config has what Docker needs, the root filesystem fits the size budget (with a report of the largest packages and directories), and `opi-selfcheck --image` passes inside the image (no user, no secret, no autologin, ...) | arm64 runner, loop mount + chroot |
| `simulate` | [Zero 3 simulation](tests/simulate.sh): the image's root filesystem booted with systemd in QEMU on 4× Cortex-A53 / 1 GiB (TCG). Covers first boot with a provisioning file, host key regeneration, filesystem growth, SSH by key and by password (from the LAN), no root login, sudo needing the password, `opi-selfcheck`, Docker with `no-new-privileges`, a real deploy of `bash-scripts/init-dozzle.sh`, and memory left. Then a real run of `opi-security-upgrade.service`, `apt dist-upgrade` from all repos, a reinstall of every package next to our files, a reboot, and all checks again | arm64 runner |
| `build-uwe5622` | uwe5622-mainline built against the image kernel's `linux-headers` package (modpost against `Module.symvers`, vermagic = image kernel) and injected into the `-uwe5622-mainline` image. See [Wi-Fi driver](#wi-fi-driver) | arm64 runner |
| `inspect-uwe5622` | The same inspection on the mainline image, plus: modules in `updates/uwe5622`, vermagic, `depmod -e` symbol check, `modprobe --show-depends sprdwl_ng` resolves to `updates/`, firmware present, Bluetooth blacklist unchanged, no driver copy in the initrd | arm64 runner, loop mount + chroot |
| `simulate-uwe5622` | The mainline image in the simulation, with the same driver commit built for the Debian simulation kernel: 10 load/unload rounds without the chip (clean probe failure, no oops/WARN/BUG, no new taint), then all `simulate` checks except the upgrade round. Integration and robustness only, not radio function | arm64 runner |

QEMU can't emulate the H618, and Armbian's board kernel has no virtio or PL011 drivers. So the
simulation boots Debian's arm64 kernel of the same release (unpacked outside dpkg) with the
image's own userland, and `inspect` covers the board-specific boot chain and kernel config.
What only real hardware can show (Wi-Fi, the Ethernet PHY, DRAM, U-Boot itself) is not covered.

To run them locally (needs Docker and root, and an arm64 machine for the image tests):
`tests/unit/run.sh`, `sudo tests/firewall-netns.sh`, `sudo tests/image-inspect.sh <img.xz>`,
`sudo tests/simulate.sh <img.xz>`.

Requires Settings → Actions → General → Workflow permissions → "Read and write" (for the pin
commit), the same as the Padavan builder.

## Flash and provision

1. Download the artifact, check it with `sha256sum -c Armbian-*.img.xz.sha`, then flash it:
   `xz -dc Armbian-*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`
   (or balenaEtcher / Raspberry Pi Imager with the `.img.xz`).
2. Write the provisioning file onto the card. The image has a single ext4 partition with
   `/boot` on it, so this needs Linux (WSL with a USB card reader works):

   ```bash
   cp opi-provision.env.example opi-provision.env   # fill it in
   sudo mount /dev/sdX1 /mnt
   sudo install -m 600 opi-provision.env /mnt/boot/opi-provision.env
   sudo umount /mnt
   shred -u opi-provision.env
   ```

3. Boot it. `opi-provision.service` creates the user, sets the host name, time zone and Wi-Fi,
   shreds `/boot/opi-provision.env`, and, if `TAILSCALE_OAUTH_CLIENT_SECRET` is set, runs
   `opi-init-tailscale-docker.sh` with your `OPI_TS_*` values. The board then joins the tailnet as
   the Tailscale container, and the "Run Bash Scripts on Orange Pi" workflow can reach it with
   the usual `OPI_*` secrets. Logs: `journalctl -u opi-provision`.

Use the same `OPI_SSH_USER` / `OPI_SSH_PASSWORD` as the repo secrets. With `OPI_TS_IP` set to the
old board's tailnet IP, the new node takes that IP over, so `OPI_TAILSCALE_IP` keeps working.
To change settings later, drop a new `/boot/opi-provision.env` and reboot (or run
`sudo opi-provision`).

Without the file, or if provisioning fails before the user exists, nobody can log in. Fix the
file on the card and boot again. A Tailscale failure leaves the user in place, so you can SSH in
over the LAN and rerun `/usr/local/lib/opi-image/opi-init-tailscale-docker.sh` by hand.

Not built in: DietPi. Its images are made by converting an existing image with a script, which
is harder to reproduce in CI than Armbian's userpatches hooks. Armbian's minimal build gives the
same small footprint.
