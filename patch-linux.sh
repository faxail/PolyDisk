#!/bin/sh
set -e

copy_config() {
	cat ./configs/${1}_defconfig ./configs/no_tty_config > ./linux/arch/arm/configs/${1}_defconfig
	cat ./configs/${1}_defconfig ./configs/tty_config > ./linux/arch/arm/configs/${1}_tty_defconfig
}

copy_config bcmrpi_cd
copy_config bcm2709_cd

(
	set -e
	cd linux
	git apply ../linux-patches/*.patch
)
