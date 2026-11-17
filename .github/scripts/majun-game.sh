#!/usr/bin/env bash
# usage: majun-game.sh <name> <work dir>   Fetches a game from majun-games.json, checks its pinned sha256 and
# prints the path of the ISO to boot. The ISO is built here and never uploaded or committed.
set -euo pipefail
name="$1"; work="$2"
list="$(dirname "$0")/majun-games.json"
field() { jq -r --arg n "$name" ".[] | select(.name == \$n) | .$1 // empty" "$list"; }

fetch() { # url pinned-sha256 file
  wget -q --tries=3 -O "$3" "$1"
  got="$(sha256sum "$3" | cut -d' ' -f1)"
  if [ -z "$2" ]; then echo "::warning::$name: sha256 not pinned, got $got" >&2
  elif [ "$got" != "$2" ]; then echo "::error::$name: sha256 mismatch for $1 (got $got)" >&2; exit 1; fi
}

mkdir -p "$work/tree"
case "$(field kind)" in
  iso-zip)
    fetch "$(field url)" "$(field sha256)" "$work/game.zip"
    unzip -q -o "$work/game.zip" -d "$work/tree"
    iso="$(find "$work/tree" -iname '*.iso' | head -n1)"
    [ -n "$iso" ] || { echo "::error::$name: no ISO in the zip" >&2; exit 1; }
    ;;
  elf)
    elf="$(field elf)"
    fetch "$(field url)" "$(field sha256)" "$work/tree/$elf"
    if [ -n "$(field assets_url)" ]; then
      fetch "$(field assets_url)" "$(field assets_sha256)" "$work/assets.7z"
      7z x -y -o"$work/tree" "$work/assets.7z" > /dev/null
    fi
    printf 'BOOT2 = cdrom0:\\%s;1\r\nVER = 1.00\r\nVMODE = NTSC\r\n' "$elf" > "$work/tree/SYSTEM.CNF"
    find "$work/tree" -maxdepth 2 | head -n 30 >&2
    genisoimage -quiet -o "$work/game.iso" -iso-level 3 -allow-lowercase -allow-multidot -udf -J "$work/tree"
    iso="$work/game.iso"
    ;;
  *) echo "::error::unknown game $name" >&2; exit 1 ;;
esac
echo "$name: iso $(stat -c %s "$iso") bytes" >&2
echo "$iso"
