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
  Removed from Armbian's minimal set: rsyslog (journald, capped at 24 MB), ALSA, man-db,
  bluez, btrfs-progs, dosfstools, wireguard-tools, figlet/toilet and a few others if present.
  The build fails rather than let a removal take a dependent package with it. Avahi, Bluetooth
  (including Armbian's `aw859a-bluetooth`) and ModemManager are masked.
- **Updates:** unattended-upgrades applies Debian security updates (`trixie-security`) only,
  never reboots by itself. Docker and Armbian packages (kernel, U-Boot, firmware): `apt upgrade`
  by hand, or flash a newer image.
- **Upgrade-safe:** the image only adds files and drop-ins (`sshd_config.d/`, `sysctl.d/`,
  `apt.conf.d/`, its own firewall unit). No package-owned file is edited, so Debian, Armbian and
  Docker upgrades never stop at a conffile prompt, unattended-upgrades never holds a package
  back, and an upgrade can't overwrite the lockdown.
- **`sudo opi-selfcheck`** on the board checks all of the above (accounts, effective sshd config
  per source address, pristine conffiles, services, firewall, sysctl, Docker). The build and the
  tests run the same script.

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
The workflow copies `bash-scripts/opi-init-tailscale-docker.sh` into the overlay at build time.

## Tests

| Job | What | Where |
|---|---|---|
| `unit` | shellcheck, plus [bats](tests/unit/) tests of `opi-provision`: the file is parsed and never executed; validation; user, sudo and docker group; keys; host name; time zone; Wi-Fi YAML escaping; Tailscale gets only its own variables; no secret in the log; failure handling. The same suite tests the configs against the real openssh, nftables and unattended-upgrades of the image's Debian release: effective sshd settings per source address, `Match` not leaking into later drop-ins, nft reload keeping other tables, apt origins | Debian container, [`tests/unit/run.sh`](tests/unit/run.sh) |
| `unit` | [Firewall with real packets](tests/firewall-netns.sh), using network namespaces for the board, a LAN/internet client and a tailnet peer. LAN v4/v6 and `tailscale0` get in. Public v4/v6, and CGNAT addresses outside `tailscale0`, are dropped. Replies, ICMP and reloads work | runner, root |
| `inspect` | [The built image](tests/image-inspect.sh): U-Boot SPL (`eGON.BT0`) at 8 KiB for the H618 boot ROM, boot script, Zero 3 device tree, kernel, initrd and `rootdev` UUID. Also: the board kernel's config has what Docker needs, the root filesystem fits the size budget (with a report of the largest packages and directories), and `opi-selfcheck --image` passes inside the image (no user, no secret, no autologin, ...) | arm64 runner, loop mount + chroot |
| `simulate` | [Zero 3 simulation](tests/simulate.sh): the image's root filesystem booted with systemd in QEMU on 4× Cortex-A53 / 1 GiB (TCG). Covers first boot with a provisioning file, host key regeneration, filesystem growth, SSH by key and by password (from the LAN), no root login, sudo needing the password, `opi-selfcheck`, Docker with `no-new-privileges`, a real deploy of `bash-scripts/init-dozzle.sh`, and memory left. Then `apt dist-upgrade` from all repos, a reinstall of every package next to our files, an `unattended-upgrade` dry run, a reboot, and all checks again | arm64 runner |

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
