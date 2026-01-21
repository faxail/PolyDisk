#!/bin/sh
set -e
base_dir=$(dirname "$0")
base_dir=$(readlink -f "$base_dir")

if [ $# -ne 2 ]; then
	1>&2 echo "Error: two arguments expected: board filename"
	exit 1
fi

board="$1"
output_filename="$2"

if [ -e "$base_dir/.tmp/polydisk-bootfs" ]; then
	rm -r "$base_dir/.tmp/polydisk-bootfs"
fi
mkdir -p "$base_dir/.tmp/polydisk-bootfs"
. "$base_dir/write-bootfs.sh" "$board" "$base_dir/.tmp/polydisk-bootfs"

DISK_SIZE_SECTORS=32768 PART_LABEL="bootfs" . "$base_dir/create-blank-img.sh" vfat "$output_filename"
sfdisk -A "$output_filename" 1
mcopy -i "$output_filename@@1M" "$base_dir/.tmp/polydisk-bootfs/"* ::/

rm -r "$base_dir/.tmp/polydisk-bootfs" &>/dev/null || true
