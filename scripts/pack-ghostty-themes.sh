#!/bin/bash
# Packs Ghostty's theme files into one file for Boo's theme gallery
# (GhosttyThemeCatalog). Hundreds of small files each take a full disk block;
# one file takes about an eighth of the space.
#
# Format: each theme starts with a line of \036 (ASCII record separator) and
# its name, followed by the theme file's lines.
#
# Usage: pack-ghostty-themes.sh <themes dir> <output file>
set -eu

src=$1
out=$2
tmp="$out.tmp"

: >"$tmp"
for file in "$src"/*; do
	[ -f "$file" ] || continue
	printf '\036%s\n' "${file##*/}" >>"$tmp"
	cat "$file" >>"$tmp"
	printf '\n' >>"$tmp"
done
mv "$tmp" "$out"
