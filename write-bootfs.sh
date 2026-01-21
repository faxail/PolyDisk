#!/bin/sh
set -e
base_dir=$(dirname "$0")
base_dir=$(readlink -f "$base_dir")

if [ $# -ne 2 ]; then
	1>&2 echo "Error: two arguments expected: board output_dir"
	exit 1
fi

board="$1"
output_dir="$2"

if [ "$board" = "rpi-zero" ] || [ "$board" = "rpi-zero-w" ]; then
	board_arch=arm
	board_kernel_file=kernel.img
elif [ "$board" = "rpi-zero-2-w" ]; then
	board_arch=arm
	board_kernel_file=kernel7.img
else
	1>&2 echo "Invalid board: $board"
	exit 1
fi

if [ -z "$RPI_FIRMWARE_VERSION" ]; then
	RPI_FIRMWARE_VERSION=stable
fi

if [ -z "$ALPINE_VERSION" ]; then
	ALPINE_VERSION=3.21
fi

download_firmware() {
	local cache_file="$base_dir/.dl-cache/$1"
	if ! [ -s "$cache_file" ]; then
		echo -n "Downloading firmware $1 ... "
		mkdir -p "$base_dir/.dl-cache"
		curl -sL -o "$cache_file" "https://raw.githubusercontent.com/raspberrypi/firmware/$RPI_FIRMWARE_VERSION/boot/$1"
	else
		echo -n "Copying cached firmware $1 ... "
	fi

	cp "$cache_file" "$output_dir/$1"
	echo Done
}

download_busybox() {
	local busybox_arch=armv5l
	if [ "$board" = "rpi-zero-2-w" ]; then
		busybox_arch=armv7l
	fi

	local cache_file="$base_dir/.dl-cache/busybox-$busybox_arch"
	if ! [ -s "$cache_file" ]; then
		echo -n "Downloading busybox ... "
		mkdir -p "$base_dir/.dl-cache"
		curl -s -o "$cache_file" "https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-$busybox_arch"
	else
		echo -n "Copying cached busybox ... "
	fi

	cp "$cache_file" "$output_dir/busybox"
	echo Done
}

download_alpine_apks() {
	local alpine_arch=armhf
	if [ "$board" = "rpi-zero-2-w" ]; then
		alpine_arch=armv7
	fi

	mkdir -p "$base_dir/.dl-cache"
	$APK_TOOL --arch $alpine_arch --allow-untrusted --no-cache \
		-X "https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/main" \
		-X "https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/community" \
		fetch -R -o "$base_dir/.dl-cache" "$@"
}

download_firmware bootcode.bin
if [ "$TTY_DEBUG" = "1" ]; then
	download_firmware start_db.elf
	download_firmware fixup_db.dat
else
	download_firmware start_cd.elf
	download_firmware fixup_cd.dat
fi

cmdline="images_fs=exfat select_fs=exfat image_type=cd image="

if [ "$TTY_DEBUG" = "1" ]; then
	if [ "$board" = "rpi-zero-2-w" ]; then
		cmdline="earlycon=pl011,mmio32,0x3f201000 console=ttyAMA0,115200 boottime $cmdline"
	else
		cmdline="earlycon=pl011,mmio32,0x20201000 console=ttyAMA0,115200 boottime $cmdline"
	fi

	sed -i -e 's/BOOT_UART=0/BOOT_UART=1/' $output_dir/bootcode.bin
fi

echo "$cmdline" > "$output_dir/cmdline.txt"

cat <<EOF > "$output_dir/config.txt"
[all]
force_turbo=1
initial_turbo=5
force_eeprom_read=0
ignore_lcd=1
hdmi_ignore_hotplug=1
disable_poe_fan=1
disable_splash=1
boot_delay=0
gpu_mem=16
device_tree=
EOF

if [ "$TTY_DEBUG" = "1" ]; then
	sed -i -e '/gpu_mem=16/d' "$output_dir/config.txt"
	cat <<EOF >> "$output_dir/config.txt"
start_debug=1
enable_uart=1
uart_2ndstage=1
EOF
fi

echo -n "Copying kernel image ... "
if [ "$board" = "rpi-zero-2-w" ]; then
	dtb_file="$base_dir/linux/arch/$board_arch/boot/dts/broadcom/bcm2710-rpi-zero-2-w.dtb"
elif [ "$board" = "rpi-zero-w" ]; then
	dtb_file="$base_dir/linux/arch/$board_arch/boot/dts/broadcom/bcm2708-rpi-zero-w.dtb"
else
	dtb_file="$base_dir/linux/arch/$board_arch/boot/dts/broadcom/bcm2708-rpi-zero.dtb"
fi

cat "$base_dir/linux/arch/$board_arch/boot/zImage" "$dtb_file" > "$output_dir/$board_kernel_file"
echo Done

download_busybox

echo -n "Copying bootfs files ... "
if [ "$TTY_DEBUG" = "1" ]; then
	cp "$base_dir/bootfs/init.sh" "$output_dir/init"
else
	sed -E '/^\s*debuglog(\s|\()/d' "$base_dir/bootfs/init.sh" > "$output_dir/init"
fi
echo Done

echo "Creating selection images ... "
mkdir -p "$base_dir/.tmp"
. "$base_dir/create-blank-img.sh" vfat "$base_dir/.tmp/polydisk-blank.img"
gzip -c "$base_dir/.tmp/polydisk-blank.img" > "$output_dir/vfat.img.gz"
. "$base_dir/create-blank-img.sh" exfat "$base_dir/.tmp/polydisk-blank.img"
gzip -c "$base_dir/.tmp/polydisk-blank.img" > "$output_dir/exfat.img.gz"
rm "$base_dir/.tmp/polydisk-blank.img"
echo Done

if [ -n "$APK_TOOL" ]; then
	download_alpine_apks exfatprogs dosfstools sfdisk losetup

	echo "Creating mkfs tools ... "
	find "$base_dir/.dl-cache" -name '*.apk' -print0 | xargs -0 -L1 gzip -dc |
		tar --warning no-unknown-keyword -i --delete --wildcards '.*' |
		tar --warning no-unknown-keyword --delete --wildcards \
			'sbin/dosfs*' \
			'sbin/fatlabel' \
			'sbin/fsck.*' \
			'usr/bin/econftool' \
			'usr/sbin/dump.exfat' \
			'usr/sbin/exfat*' \
			'usr/sbin/fsck.*' \
			'usr/sbin/tune.*' |
		gzip > "$output_dir/mkfs-tools.tar.gz"
	echo Done
fi
