#!/bin/sh


# run ESP.sh or do that manually. 
# cgdisk /dev/nvme0n1
# New partition
# 512M
# ef00 for /boot

# New partition
# 8e00
# ArchLVM

#Verify


# Formats the selected partition and mounts it at `/boot`
chooseesppart() {

	# Outputs the number assigned to selected partition
	declare -i esppartnumber
	esppartnumber=$(dialog 	--title "Please select your ESP partition to be formated and mounted at /boot:" \
							--menu "$(lsblk) " 0 0 0 $(listpartnumb) 3>&1 1>&2 2>&3 3>&1)
	
	# Exit the process if the user selects <cancel> instead of a partition.
	[ $? -eq 1 ] && error "You didn't select any partition. Exiting..."

	# This is the desired partition.
	esppart=$( blkid -o list | awk '{print $1}'| grep "^/" | tr ' ' '\n' | sed -n ${esppartnumber}p)
	
	# Ask user for confirmation.
	dialog --title "Please Confirm" \
	--yesno "Are you sure you want to format partition \"$esppart\" (after final confirmation)?" 0 0
}

chooseesppart
while [ $? -eq 1 ] ; do
	chooseesppart
done

#	Test:
#	echo $esppart

# Formats selected esp partition.
mkfs.fat -F 32 $esppart

# Mounts the selected esp partition to /mnt/boot
mkdir /mnt/boot && mount $esppart /mnt/boot


cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
pacman -Syy pacman-contrib

curl -L "https://www.archlinux.org/mirrorlist/?country=BE&country=DK&country=FI&country=FR&country=DE&country=GR&country=IT&country=LU&country=MK&country=NO&country=RS&country=SK&country=SI&protocol=https&ip_version=4" > /etc/pacman.d/mirrorlist.backup
sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist.backup

rankmirrors -n 6 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist

pacamn -Syy

pacstrap /mnt base

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt

