#!/usr/bin/env bash
# License: GNU GPLv3

# setfont sun12x22 #HDPI
# dd bs=4M if=path/to/arch.iso of=/dev/sdx status=progress oflag=sync
exit # Don't use this script
export multi_lib_bool=true
export timezone="Europe/Athens"
export lang="en_US.UTF-8"

if [ ! -d "/sys/firmware/efi" ]; then
	echo "Please use UEFI mode." && exit
fi

get_drive() {
	local dialogOUT
    # Sata and NVME drives array
    drives=( $(/usr/bin/ls -1 /dev | grep -P "sd.$|nvme.*$" | grep -v "p.$") )

	# Enumerates every drive like so: 
	# 1 /dev/sda 2 /dev/sdb 3 /dev/sdc 4 /dev/nvme0n1 .....
    local -i n=0
	for i in "${drives[@]}" ; do
		dialog_prompt="$dialog_prompt $n $i"
        ((n++))
	done

    # Prompts user to select one of the available sda or nvme drives.
    
	dialogOUT=$(dialog --title "Select your Hard-drive" \
        --menu "$(lsblk)" 0 0 0 $dialog_prompt 3>&1 1>&2 2>&3 3>&1 ) || exit

	HARD_DRIVE="/dev/${drives[$dialogOUT]}"
	[[ $HARD_DRIVE == *"nvme"* ]] && HARD_DRIVE="${HARD_DRIVE}p"

    # Converts dialog output to the actuall name of the selected drive.
    echo "$HARD_DRIVE"
}

partition_drive() {
	# Uses fdisk to create an "EFI System" partition  (500M),
	# a "Linux root" partition and a "linux home" partition.
	cat <<-EOF | fdisk --wipe-partitions always $1
		g
		n
		1

		+500M
		t
		1
		n
		2

		+38G
		t
		2
		24
		n
		3


		t
		3
		28
		w
	EOF
}

format_mount_parts() {
	yes | mkfs.ext4 -L "Arch" ${1}2
	mount "${1}2" /mnt

	yes | mkfs.fat  -n "ESP" -F 32 ${1}1
	mkdir /mnt/boot && mount "${1}1" /mnt/boot

	#yes | mkfs.ext4 -L "Home" ${1}3
	mkdir /mnt/home && mount "${1}3" /mnt/home
}


## Archlinux installation ##
get_username() {
	# Ask for the name of the main user.
	local get_name
	read -rep $'Please enter a name for a user account: \n' get_name

	while ! echo "$get_name" | grep -q "^[a-z_][a-z0-9_-]*$"; do
		read -rep $'Invalid name. Try again: \n' get_name
	done
    echo $get_name
}


get_pass() {
	# Pass the name of the user as an argument.
    local cr le_usr get_pwd_pass check_4_pass
	cr=$(echo $'\n.'); cr=${cr%.}
	le_usr="$1"
    read -rsep $"Enter a password for $le_usr: $cr" get_pwd_pass
    read -rsep $"Retype ${le_usr}'s password: $cr" check_4_pass

    while ! [ "$get_pwd_pass" = "$check_4_pass" ]; do unset check_4_pass
        read -rsep \
		$"Passwords didn't match. Retype ${le_usr}'s password: " get_pwd_pass
        read -rsep $"Retype ${le_usr}'s password: " check_4_pass
    done

    echo "$get_pwd_pass"
}


systemd_boot() {
	# Installs and configures systemd-boot.
	bootctl --path=/boot install

	cat > /boot/loader/loader.conf <<-EOF
		default  ArchLinux
		console-mode max
		editor   no
	EOF

	#  UUID of the partition mounted as "/"
	local root_id="$(lsblk --list -fs -o MOUNTPOINT,UUID | \
					grep "^/ " | awk '{print $2}')"

	local kernel_parms="rw quiet" # Default kernel parameters.

	# I need this to avoid random crashes on my main pc (AMD R5 1600)
	# https://forum.manjaro.org/t/amd-ryzen-problems-and-fixes/55533
	lscpu | grep -q "AMD Ryzen" && kernel_parms="$kernel_parms idle=nowait"

	# Bootloader entry using `linux` kernel:
	cat > /boot/loader/entries/ArchLinux.conf <<-EOF
		title   Arch Linux
		linux   /vmlinuz-linux
		initrd  /${cpu}-ucode.img
		initrd  /initramfs-linux.img
		options root=UUID=${root_id} $kernel_parms
	EOF

	# A hook to update systemd-boot after systemd package updates.
	cat > /etc/pacman.d/hooks/bootctl-update.hook <<-EOF
		[Trigger]
		Type = Package
		Operation = Upgrade
		Target = systemd
		[Action]
		Description = Updating systemd-boot
		When = PostTransaction
		Exec = /usr/bin/bootctl update
	EOF
}


grub_mbr() {
	# grub option is not tested much and only works on MBR partition tables
	# Avoid using it as is.
	local grub_path
	pacman --noconfirm --needed -S grub
	grub_path=$(
		lsblk --list -fs -o MOUNTPOINT,PATH | grep "^/ " | awk '{print $2}')
	grub-install --target=i386-pc $grub_path
	grub-mkconfig -o /boot/grub/grub.cfg
}


core_arch_install() {
	systemctl enable --now systemd-timesyncd.service
	ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime
	hwclock --systohc
	sed -i "s/#${lang} UTF-8/${lang} UTF-8/g" /etc/locale.gen
	locale-gen > /dev/null 2>&1
	echo 'LANG="'$lang'"' > /etc/locale.conf

	echo $hostname > /etc/hostname
	cat > /etc/hosts <<-EOF
		#<ip-address>   <hostname.domain.org>    <hostname>
		127.0.0.1       localhost.localdomain    localhost
		::1             localhost.localdomain    localhost
		127.0.1.1       ${hostname}.localdomain  $hostname
	EOF

	# Enable [multilib] repo, if multi_lib_bool == true
	if [ "$multi_lib_bool" = true  ]; then
		sed -i '/\[multilib]/,+1s/^#//' /etc/pacman.conf
		pacman -Sy && pacman -Fy
	fi

	# Install cpu microcode.
	case $(lscpu | grep Vendor | awk '{print $3}') in
		"GenuineIntel") local cpu="intel";;
		"AuthenticAMD") local cpu="amd" ;;
	esac

	pacman --noconfirm --needed -S "${cpu}-ucode"

	# This folder is needed for pacman hooks
	mkdir -p /etc/pacman.d/hooks
	# Install bootloader
	if [ -d "/sys/firmware/efi" ]; then
		systemd_boot
		pacman --noconfirm --needed -S efibootmgr
	else
		grub_mbr
	fi

	# Set root password
	if [ "$root_password" ]; then
		printf "${root_password}\\n${root_password}" | passwd >/dev/null 2>&1
	else
		echo "ROOT PASSWORD IS NOT SET!!!!"
		# find a way to fix this.
		#passwd -l root
	fi

	useradd -m -g wheel -G power -s /bin/bash "$name" # Create user
	echo "$name:$user_password" | chpasswd 			# Set user password.

	echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
	chmod 440 /etc/sudoers.d/wheel

	# Use all cpu cores to compile packages
	sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf
	sed -i "s/^#Color/Color/;/Color/a ILoveCandy" /etc/pacman.conf

    printf '\ninclude "/usr/share/nano/*.nanorc"\n' >> /etc/nanorc

	echo "blacklist pcspkr" >> /etc/modprobe.d/disablebeep.conf

	# Use all cpu cores to compile packages
	sudo sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf

	# Creates a swapfile. 2Gigs in size.
	fallocate -l 2G /swapfile
	chmod 600 /swapfile
	mkswap /swapfile >/dev/null 2>&1
	swapon /swapfile
	printf "\\n/swapfile none swap defaults 0 0\\n" >> /etc/fstab
	printf "vm.swappiness=10\\nvm.vfs_cache_pressure=50" \
			>> /etc/sysctl.d/99-sysctl.conf
	
	systemctl enable NetworkManager
}

hostname=$(read -rep $'Enter computer\'s hostname: \n' var; echo $var) || exit
name=$(get_username) || exit
user_password="$(get_pass $name)" || exit
# If root_passwdrd is not set, root login should be disabled.
# root_password="$(get_pass root)"
export hostname name user_password root_password

# Select main drive
HARD_DRIVE=$(get_drive) || exit

# Partition drive. 		!!! DELETES ALL DATA !!!
#clear; partition_drive $HARD_DRIVE

# Formats the drive. 	!!! DELETES ALL DATA !!!
format_mount_parts "$HARD_DRIVE"

timedatectl set-ntp true

pacstrap /mnt base base-devel git linux linux-headers linux-firmware \
			  man-db man-pages usbutils nano pacman-contrib expac arch-audit \
			  networkmanager openssh

genfstab -U /mnt > /mnt/etc/fstab
export -f systemd_boot grub_mbr core_arch_install
arch-chroot /mnt bash -c core_arch_install