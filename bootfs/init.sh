#!/root/busybox sh
export PATH=/root
GADGET_PATH=/sys/kernel/config/usb_gadget/g0
LUN_PATH=$GADGET_PATH/functions/mass_storage.usb0/lun.0

images_fs=vfat
select_fs=vfat
image_type=
image=
show_boottime=0

udc_name=
select_btn_pressed_init=0

debuglog() { 1>&2 echo $*; }

panic() {
	set_led timer
	1>&2 echo $*
	1>&2 echo "PANIC!!! Dropping to shell"
	busybox mount -t proc none /proc
	busybox sh
	exit 1
}

set_led() {
	echo $1 > /sys/class/leds/ACT/trigger
}

get_args() {
	busybox cat /root/cmdline.txt | busybox xargs -n1 busybox echo
}

try_loop() {
	local tries=$1
	local retry=0
	shift
	while ! busybox "$@"; do
		if [ $retry -eq 0 ]; then
			retry=1
			debuglog "Retrying: $*"
		fi

		tries=$(($tries - 1))
		if [ $tries -lt 1 ]; then
			panic
		fi
		busybox sleep 0.5
	done
}

try_get_proc_cmdline() {
	if ! [ -e /proc/cmdline ] && ! busybox mount -t proc none /proc 2> /dev/null; then
		return 1
	fi

	busybox cat /proc/cmdline 2> /dev/null
}

try_get_kmsg() {
	if ! [ -e /proc/kmsg ] && ! busybox mount -t proc none /proc 2> /dev/null; then
		return 1
	fi

	busybox cat /proc/kmsg >> /kmsg.log &
	pid=$!
	busybox sleep 1
	busybox kill -s SIGINT $pid
	busybox cat /kmsg.log
}

try_cat_lf() {
	if [ -f "$1" ]; then
		busybox sed -E $'1s/^\xEF\xBB\xBF//; s/\r$//; $a\\' "$1"
	fi
}

setup_devices() {
	busybox mkdir /sys /proc /select /select-live
	busybox mount -t sysfs sys /sys
	busybox mount -t configfs none /sys/kernel/config
	busybox mknod /dev/null c 1 3
	busybox mknod /dev/mmcblk0 b 179 0
	busybox mknod /dev/mmcblk0p1 b 179 1
	busybox mknod /dev/mmcblk0p2 b 179 2
	busybox mknod /dev/loop0 b 7 0
	busybox mknod /dev/polydisk-info c 241 0

	for cpu in $(busybox find /sys/devices/system/cpu/ -mindepth 1 -maxdepth 1 -type d -name 'cpu[0-9]'); do
		echo ondemand > $cpu/cpufreq/scaling_governor
	done

	udc_name=$(busybox ls -1 /sys/class/udc)
	if [ -z "$udc_name" ]; then
		panic "no UDC found"
	fi

	if busybox grep -qF 'select_btn init=1' /dev/polydisk-info; then
		select_btn_pressed_init=1
	fi
}

imgs_part_exists() {
	busybox head -c 0 /dev/mmcblk0p2 &> /dev/null
}

load_mkfs_tools() {
	busybox tar -C / -xzf /root/mkfs-tools.tar.gz
}

is_select_btn_pressed() {
	busybox grep -qE 'select_btn .*cur=1' /dev/polydisk-info
}

remount_imgs() {
	if [ "$1" = "ro" ] || [ "$1" = "rw" ]; then
		if ! busybox mount -o remount,$1 /dev/imgs /imgs; then
			panic "Error: could not remount /imgs $1"
		fi
	else
		panic "remount_imgs: Invalid argument"
	fi
}

remount_root() {
	if [ "$1" = "ro" ] || [ "$1" = "rw" ]; then
		if ! busybox mount -o remount,$1 /dev/root /root; then
			panic "Error: could not remount /root $1"
		fi
	else
		panic "remount_root: Invalid argument"
	fi
}

save_image_params() {
	new_params=$(busybox cat)
	if [ -z "$new_params" ]; then
		return 0
	fi

	{
		busybox sed -E '/^(image_type|image|inquiry_vendor|inquiry_product|inquiry_revision|usbids|strings_.*)=/d' /cmdline
		echo "$new_params"
	} > /cmdline.new

	if [ -s /cmdline.new ]; then
		remount_root rw
		busybox cat /cmdline.new | busybox sed -E 's/^(.* .*)$/"\1"/' | busybox tr '\n' ' ' > /root/cmdline.txt.tmp
		busybox mv /root/cmdline.txt.tmp /root/cmdline.txt
		result=$?
		busybox sync
		remount_root ro
		return $result
	else
		return 1
	fi
}

load_select_img() {
	if [ -f "/select.img" ]; then
		return 0
	fi

	if ! busybox gzip -dc "/root/$select_fs.img.gz" > /select.img; then
		panic "Error: could not load /root/$select_fs.img.gz"
	fi

	if ! busybox losetup -P /dev/loop0 /select.img; then
		panic "Error: could not bind loop device"
	fi

	local loop_dev=$(busybox cat /sys/block/loop0/loop0p1/dev | busybox tr ':' ' ')
	if [ -z "$loop_dev" ]; then
		panic "Error: loop device does not have partitions"
	fi

	busybox mknod /dev/loop0p1 b $loop_dev
}

select_mounted=0
mount_select_img() {
	if [ $select_mounted -eq 0 ]; then
		load_select_img

		debuglog "Mounting /select ..."
		if ! busybox mount -t "$select_fs" -o noatime /dev/loop0p1 /select; then
			panic "Error: could not mount /select.img"
		fi
		debuglog "Mounted /select"
		select_mounted=1
	fi
}

umount_select_img() {
	if [ $select_mounted -eq 1 ]; then
		debuglog "Unmounting /select ..."
		try_loop 30 umount /select
		debuglog "Unmounted /select"
		select_mounted=0
	fi
}

find_selected_file() {
	local file=$(busybox find "$1" -type f -mindepth 1 -maxdepth 1 \( -iname '*.iso' -o -iname '*.img' -o -iname '*.raw' \) -not -iname '(current) *' | busybox head -n 1)
	if [ -n "$file" ]; then
		echo "$file"
		return 0
	fi

	file=$(busybox find "$1" -type f -mindepth 1 -maxdepth 1 -iname '(current) *' | busybox head -n 1)
	if [ -n "$file" ]; then
		echo "$file"
		return 0
	fi

	return 1
}

is_udc_binded() {
	if [ -n "$(busybox cat $GADGET_PATH/UDC)" ]; then
		return 0
	else
		return 1
	fi
}

attach_usb() {
	debuglog "Connecting USB ..."
	if ! is_udc_binded && ! echo $udc_name > $GADGET_PATH/UDC; then
		panic "Error: Could not bind to UDC"
	fi
	echo connect > /sys/class/udc/$udc_name/soft_connect
	wait_for_usb_state "configured"
	busybox sleep 1
}

detach_usb() {
	if is_udc_binded; then
		debuglog "Disconnecting USB ..."
		echo disconnect > /sys/class/udc/$udc_name/soft_connect
		wait_for_usb_state "not attached"
		busybox sleep 2
	fi
}

wait_for_usb_state() {
	debuglog "Waiting for USB state $1 ..."
	while ! [ "$(busybox cat /sys/class/udc/$udc_name/state)" = "$1" ]; do
		busybox sleep 0.1
	done
	debuglog "USB state now $1"
}

is_select_img_dirty() {
	if [ "$select_fs" = "exfat" ] && [ $((0x$(busybox xxd -s 106 -l 1 -p /dev/loop0p1) & 2)) -eq 2 ]; then
		return 0
	fi

	return 1
}

get_selected_file_live() {
	if busybox mount -t "$select_fs" -o ro /dev/loop0p1 /select-live > /dev/null; then
		if [ -n "$1" ]; then
			get_file_params "$1"
		else
			find_selected_file /select-live/
		fi
		busybox umount /select-live > /dev/null
	fi
}

wait_for_eject() {
	debuglog "Waiting for eject ..."
	while [ -n "$(busybox cat $LUN_PATH/file)" ]; do
		busybox sleep 0.1
		if is_select_btn_pressed; then
			debuglog "Forcing eject ..."
			echo 1 > $LUN_PATH/forced_eject
			busybox sleep 0.5
			detach_usb
			echo > $LUN_PATH/file
			busybox sleep 0.5
		fi
	done
	debuglog "Ejected"
}

wait_for_eject_or_new_selection() {
	debuglog "Waiting for eject or new selection ..."
	local selected_file=$(get_selected_file_live)
	local new_selected_file=""
	while [ -n "$(busybox cat $LUN_PATH/file)" ]; do
		busybox sleep 0.1
		if is_select_btn_pressed; then
			debuglog "Forcing eject ..."
			echo 1 > $LUN_PATH/forced_eject
			busybox sleep 0.5
			detach_usb
			echo > $LUN_PATH/file
			busybox sleep 0.5
		fi

		new_selected_file=$(get_selected_file_live)
		if ! [ "$new_selected_file" = "$selected_file" ] && ! is_select_img_dirty; then
			debuglog "Image changed to $new_selected_file"
			if get_selected_file_live "$new_selected_file" | save_image_params; then
				debuglog "Image params saved"
				set_led none
				busybox sleep 0.2
				set_led default-on
				busybox sleep 0.1
				set_led none
				busybox sleep 0.2
				set_led actpwr
			else
				panic "Error: could not save params"
			fi
			selected_file=$new_selected_file
		fi
	done
	debuglog "Ejected"
}

wait_for_select_btn_pressed() {
	debuglog "Waiting for button pressed ..."
	set_led none
	local seq=0
	while ! is_select_btn_pressed; do
		busybox sleep 0.1

		if [ $seq -eq 0 ]; then
			set_led default-on
		elif [ $seq -eq 1 ]; then
			set_led none
		elif [ $seq -eq 2 ]; then
			set_led default-on
		elif [ $seq -eq 3 ]; then
			set_led none
		fi
		seq=$((($seq + 1) % 10))
	done
	debuglog "Button pressed"
}

wait_for_reboot() {
	set_led none
	debuglog "Waiting for reboot ..."
	while true; do
		busybox sleep 1
	done
}

is_usb_attached() {
	if [ "$(busybox cat /sys/class/udc/$udc_name/state)" = "configured" ]; then
		return 0
	else
		return 1
	fi
}

configure_lun() {
	debuglog "Configuring mode=$1 file=$2 ..."
	local cdrom=1
	local ro=1
	if [ "$1" = "ro" ]; then
		cdrom=0
		ro=1
	elif [ "$1" = "rw" ]; then
		cdrom=0
		ro=0
	fi

	try_loop 30 sh -c "echo > $LUN_PATH/file"
	try_loop 30 sh -c "echo $cdrom > $LUN_PATH/cdrom"
	try_loop 30 sh -c "echo $ro > $LUN_PATH/ro"
	try_loop 30 sh -c "echo 1 > $LUN_PATH/removable"
	try_loop 30 sh -c "echo $2 > $LUN_PATH/file"
	debuglog "Configured"
}

bind_select_img() {
	detach_usb
	umount_select_img

	configure_lun rw /dev/loop0
	echo "0x1d6b" > $GADGET_PATH/idVendor
	echo "0x0104" > $GADGET_PATH/idProduct
	echo "0x0100" > $GADGET_PATH/bcdDevice
	echo -n "PolyDiskPolyDisk Select 0100"  > $LUN_PATH/inquiry_string
	busybox mkdir -p $GADGET_PATH/strings/0x0409
	echo "PolyDisk" > $GADGET_PATH/strings/0x0409/manufacturer
	echo "PolyDisk Select" > $GADGET_PATH/strings/0x0409/product
	attach_usb
}

refresh_select_files() {
	mount_select_img

	busybox rm -rf "/select/*" &> /dev/null || true
	busybox mkdir /select/images
	busybox find /imgs/ -type f \( -iname '*.iso' -o -iname '*.img' -o -iname '*.raw' \) | busybox sed -E 's|^/imgs/||' |
	while read -r file; do
		local dir=$(busybox dirname "$file")
		if [ -n "$dir" ] && ! [ "$dir" = "." ]; then
			busybox mkdir -p "/select/images/$dir"
		fi

		{
			try_cat_lf "/imgs/$dir/all.ini"
			try_cat_lf "/imgs/$file.ini"
			printf 'image=%s\n' "/imgs/$file"
		} | busybox sed '/=/!d' > "/select/images/$file"
		busybox touch -r "/imgs/$file" "/select/images/$file"
	done

	busybox touch "/select/_ Move or copy the desired image file here and eject to apply"
	if [ $show_boottime -eq 1 ]; then
		local boottime=$(busybox grep -F 'boottime ' /dev/polydisk-info)
		if [ -n "$boottime" ]; then
			busybox touch "/select/_ $boottime"
		fi
	fi

	local proc_cmdline=$(try_get_proc_cmdline)
	if [ -n "$proc_cmdline" ]; then
		echo "$proc_cmdline" > "/select/_ cmdline.txt"
		try_get_kmsg > "/select/_ kmsg.log"
	fi

	if [ -n "$image" ]; then
		local image_name=$(busybox basename "$image")
		if [ "$image_type" = "rw" ] && ! echo -n "$image_name" | busybox grep -qiE '\.rw\.[^.]+$'; then
			image_name=$(busybox sed -E 's/\.([^.]+)$/.rw.\1/')
		fi

		busybox touch -r "$image" "/select/(current) $image_name"
	fi
}

get_file_params() {
	if [ -z "$1" ]; then
		printf 'image_type=\nimage=\n'
		return 0
	fi

	{
		busybox cat "$1"
		if echo -n "$1" | busybox grep -qiE '\.rw\.(img|raw)$'; then
			printf '\nimage_type=rw\n'
		elif echo -n "$1" | busybox grep -qiE '\.(img|raw)$'; then
			printf '\nimage_type=ro\n'
		else
			printf '\nimage_type=cd\n'
		fi
	} | busybox sed -E '/^\s*$/d'
}

setup_devices

get_args > /cmdline
while read -r arg; do
	arg_name=$(echo -n "$arg" | busybox cut -d'=' -f1)
	arg_value=$(echo -n "$arg" | busybox cut -d'=' -f2-)
	debuglog "$arg_name: $arg_value"
	if [ "$arg_name" = "select_fs" ]; then
		select_fs=$arg_value
	elif [ "$arg_name" = "images_fs" ]; then
		images_fs=$arg_value
	elif [ "$arg_name" = "image_type" ]; then
		image_type=$arg_value
	elif [ "$arg_name" = "image" ]; then
		image=$arg_value
	elif [ "$arg" = "boottime" ]; then
		show_boottime=1
	fi
done < /cmdline

if ! imgs_part_exists; then
	if ! load_mkfs_tools; then
		panic "Could not load mkfs-tools"
	fi

	if [ "$images_fs" = "exfat" ]; then
		part_type=7
	else
		part_type=c
	fi

	if ! echo "/dev/mmcblk0p2 : type=$part_type" | /sbin/sfdisk -a --no-reread --no-tell-kernel -q /dev/mmcblk0; then
		panic "Failed to create the partition"
	fi

	part_info=$(/sbin/sfdisk -d /dev/mmcblk0 | busybox grep -F '/dev/mmcblk0p2 :')
	part_start=$(echo "$part_info" | busybox grep -oE 'start= *[0-9]+' | busybox cut -d'=' -f2)
	part_size=$(echo "$part_info" | busybox grep -oE 'size= *[0-9]+' | busybox cut -d'=' -f2)
	if [ -z "$part_start" ] || [ -z "$part_size" ]; then
		panic "Cannot determine the offset and size of the partition"
	fi
	part_start=$(($part_start * 512))
	part_size=$(($part_size * 512))

	debuglog "Created partition: start=$part_start size=$part_size"
	if ! /sbin/losetup --offset $part_start --sizelimit $part_size /dev/loop0 /dev/mmcblk0; then
		panic "losetup failed"
	fi

	if [ "$images_fs" = "exfat" ]; then
		/usr/sbin/mkfs.exfat -q -L "PolyDisk" /dev/loop0
	else
		/sbin/mkfs.vfat -F 32 -n "PolyDisk" /dev/loop0
	fi

	if [ $? -ne 0 ]; then
		panic "Failed to format the partition"
	fi

	wait_for_reboot
fi

if [ $select_btn_pressed_init -eq 0 ]; then
	wait_for_eject
	busybox sync
	remount_imgs ro
	detach_usb
	wait_for_select_btn_pressed
	set_led actpwr
fi

refresh_select_files
bind_select_img
wait_for_eject_or_new_selection

detach_usb
mount_select_img
selected_file=$(find_selected_file /select/)
if ! echo -n "$selected_file" | busybox grep -qiE '/\(current\) [^/]+'; then
	if get_file_params "$selected_file" | save_image_params; then
		set_led none
	else
		panic "Error: could not save params"
	fi
fi

umount_select_img
wait_for_reboot
