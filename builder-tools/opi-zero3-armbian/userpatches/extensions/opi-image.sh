# shellcheck shell=bash
# Armbian extension (ENABLE_EXTENSIONS=opi-image): the steps that must run after
# customize-image.sh, because Armbian itself changes the image after that script.

# Armbian installs armbian-config (a menu tool, with whiptail, Tcl/expect, btrfs/f2fs/ntfs tools)
# after customize-image.sh. A Docker host managed over SSH doesn't use it; Armbian's autoremove,
# which runs next, takes the packages it pulled in.
function post_repo_customize_image__opi_remove_armbian_config() {
	if chroot "${SDCARD}" dpkg-query -W -f='${Status}' armbian-config 2> /dev/null | grep -q '^install ok installed'; then
		local extra
		extra="$(chroot "${SDCARD}" apt-get -s purge armbian-config | awk '/^Purg /{ print $2 }' | grep -vx armbian-config || true)"
		[[ -z "$extra" ]] || exit_with_error "Removing armbian-config would also remove" "${extra//$'\n'/ }"
		display_alert "opi-image" "removing armbian-config" "info"
		chroot_sdcard DEBIAN_FRONTEND=noninteractive apt-get -y -q purge armbian-config
	fi
	rm -f "${SDCARD}"/etc/apt/sources.list.d/armbian-config.sources
}

# Armbian ships /var/lib/apt/lists copied from its host-side cache, uncompressed (~60 MB). apt
# reads compressed lists as well, and 50opi-lists keeps them compressed on later updates.
function pre_prepare_partitions__opi_compress_apt_lists() {
	local f
	for f in "${SDCARD}"/var/lib/apt/lists/*_Packages "${SDCARD}"/var/lib/apt/lists/*_Sources; do
		# (an unmatched pattern stays literal; compressed lists end in .gz/.lz4 and don't match)
		if [[ -f "$f" ]]; then gzip -9n "$f"; fi
	done
	# Not used (Acquire::Languages "none")
	rm -f "${SDCARD}"/var/lib/apt/lists/*_Translation-*
	display_alert "opi-image" "apt lists compressed: $(du -sh "${SDCARD}"/var/lib/apt/lists | cut -f1)" "info"
}
