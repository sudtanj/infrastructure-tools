# shellcheck shell=bash
# Armbian extension (ENABLE_EXTENSIONS=opi-image): the steps that must run after
# customize-image.sh, because Armbian itself changes the image after that script.

# Armbian installs armbian-config (a menu tool, with Python, whiptail, Tcl/expect, btrfs/f2fs/ntfs
# tools) after customize-image.sh. A Docker host managed over SSH doesn't use it. Its autoremove
# doesn't take all of that back (Python stayed), so purge every package that wasn't installed when
# customize-image.sh finished (its list: /var/lib/opi-image-packages).
function post_repo_customize_image__opi_remove_armbian_config() {
	local before="${SDCARD}/var/lib/opi-image-packages" added extra
	[[ -s "$before" ]] || exit_with_error "opi-image" "no package list from customize-image.sh"
	added="$(chroot "${SDCARD}" dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
		| awk '$1 == "ii" { print $2 }' | LC_ALL=C sort | LC_ALL=C comm -13 "$before" -)"
	rm -f "$before"
	if [[ -n "$added" ]]; then
		# Never take a package that was there before
		# shellcheck disable=SC2086 # one package name per word
		extra="$(chroot "${SDCARD}" apt-get -s purge $added | awk '/^Purg /{ sub(/:.*/, "", $2); print $2 }' \
			| grep -vxF -f <(printf '%s\n' "$added") || true)"
		[[ -z "$extra" ]] || exit_with_error "Removing what Armbian added would also remove" "${extra//$'\n'/ }"
		display_alert "opi-image" "removing what Armbian installed after customize-image.sh" "${added//$'\n'/ }"
		# shellcheck disable=SC2086
		chroot_sdcard DEBIAN_FRONTEND=noninteractive apt-get -y -q purge $added
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
