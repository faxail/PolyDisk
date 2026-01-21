#!/bin/sh
set -e -o pipefail

if [ $# -ne 2 ]; then
	1>&2 echo "Error: two arguments expected: fs_type file_name"
	exit 1
fi

fs_type="$1"
file_name="$2"
if [ -z "$DISK_SIZE_SECTORS" ]; then
	DISK_SIZE_SECTORS=65536
fi
if [ -z "$PART_LABEL" ]; then
	PART_LABEL="PolyDisk"
fi
part_start_sector=2048
part_size_sectors=$(($DISK_SIZE_SECTORS - $part_start_sector))

_fallocate() {
	size="$1"
	filename="$2"

	if [ -f "$filename" ]; then
		rm "$filename"
	fi

	if ! fallocate "$filename" 2>/dev/null; then
		dd if=/dev/zero of="$filename" bs="$size" count=1 status=none
	fi
}

create_files() {
	_fallocate $(($DISK_SIZE_SECTORS * 512)) "$file_name"
	_fallocate $(($part_size_sectors * 512)) "$file_name.part"
}

if [ "$fs_type" = "vfat" ]; then
	create_files
	mkfs.vfat -n "$PART_LABEL" "$file_name.part"
	part_type=c
elif [ "$fs_type" = "exfat" ]; then
	create_files
	mkfs.exfat -L "$PART_LABEL" "$file_name.part"
	part_type=7
else
	1>&2 echo "Error: invalid filesystem type: $fs_type"
	exit 1
fi

cat <<EOF | sfdisk "$file_name"
label: dos
device: /fakedev
unit: sectors
sector-size: 512

/fakedev1 : start=$part_start_sector, size=$part_size_sectors, type=$part_type
EOF

dd "if=$file_name.part" "of=$file_name" bs=$(($part_start_sector * 512)) seek=1 conv=notrunc
rm "$file_name.part"
