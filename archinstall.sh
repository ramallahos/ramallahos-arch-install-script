#!/bin/bash

# USERNAME=safwan
# PASSWORD=1234
# #LUKS_PASSWORD=1234   # if FS=luks  and comment PASSWORD
# NAME_OF_MACHINE=safwan #hostname
# PKGFILE="https://raw.githubusercontent.com/ramallahos/ramallahos-sh/upackages.txt"
# AUR_HELPER=paru
# INSTALL_TYPE=FULL # or MINIMAL (server)
# MOUNT_OPTIONS=noatime,compress=zstd,ssd,commit=120 # for ssd
# #MOUNT_OPTIONS=noatime,compress=zstd,commit=120 # for hdd
# DISK=/dev/nvme0n1
# FS=ext4                  # btrfs ext4 luks
# TIMEZONE="$( curl --fail https://ipapi.co/timezone )"
# KEYMAP=us            # us by ca cf cz de dk es et fa fi fr gr hu il it lt lv mk nl no pl ro ru sg ua uk
# SWAPSIZE=8192        # swapfile size in mb
# LOGS=yes
# REFLECTOR=no
# CUSTOM_SCRIPT="https://raw.githubusercontent.com/ramallahos/ramallahos-sh/user.sh" # script that is executed in $USERNAME 's home directory



if [[ "$(id -u)" != "0" ]]; then
    echo -ne "ERROR! This script must be run under the 'root' user!\n"
    exit 0
elif awk -F/ '$2 == "docker"' /proc/self/cgroup | read -r; then
    echo -ne "ERROR! Docker container is not supported (at the moment)\n"
    exit 0
elif [[ -f /.dockerenv ]]; then
    echo -ne "ERROR! Docker container is not supported (at the moment)\n"
    exit 0
elif [[ ! -e /etc/arch-release ]]; then
    echo -ne "ERROR! This script must be run in Arch Linux!\n"
    exit 0
elif [[ -f /var/lib/pacman/db.lck ]]; then
    rm -f /var/lib/pacman/db.lck
    # exit 0
fi

main() {
  ( bash $1 )|& tee main.log
}

main << MAIN
timedatectl set-ntp true
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
pacman -S --noconfirm --needed archlinux-keyring pacman-contrib terminus-font reflector rsync grub gptfdisk btrfs-progs glibc
setfont ter-v22b
if [[ "$REFLECTOR" == "yes" ]]; then
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    reflector -a 48 -c $( curl -4 ifconfig.co/country-iso ) -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist
fi
mkdir /mnt &>/dev/null
umount -A --recursive /mnt
sgdisk -Z ${DISK}
sgdisk -a 2048 -o ${DISK}
sgdisk -n 1::+1M --typecode=1:ef02 --change-name=1:'BIOSBOOT' ${DISK}
sgdisk -n 2::+300M --typecode=2:ef00 --change-name=2:'EFIBOOT' ${DISK}
sgdisk -n 3::-0 --typecode=3:8300 --change-name=3:'ROOT' ${DISK}
[[ ! -d "/sys/firmware/efi" ]] && sgdisk -A 1:set:2 ${DISK}
partprobe ${DISK}

subvolumesetup () {
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@tmp
    btrfs subvolume create /mnt/@.snapshots
    umount /mnt
    mount -o ${MOUNT_OPTIONS},subvol=@ ${partition3} /mnt
    mkdir -p /mnt/{home,var,tmp,.snapshots}
    mount -o ${MOUNT_OPTIONS},subvol=@home ${partition3} /mnt/home
    mount -o ${MOUNT_OPTIONS},subvol=@tmp ${partition3} /mnt/tmp
    mount -o ${MOUNT_OPTIONS},subvol=@var ${partition3} /mnt/var
    mount -o ${MOUNT_OPTIONS},subvol=@.snapshots ${partition3} /mnt/.snapshots
}

if [[ "${DISK}" =~ "nvme" ]]; then
    partition2=${DISK}p2
    partition3=${DISK}p3
else
    partition2=${DISK}2
    partition3=${DISK}3
fi

if [[ "${FS}" == "btrfs" ]]; then
    mkfs.vfat -F32 -n "EFIBOOT" ${partition2}
    mkfs.btrfs -L ROOT ${partition3} -f
    mount -t btrfs ${partition3} /mnt
    subvolumesetup
elif [[ "${FS}" == "ext4" ]]; then
    mkfs.vfat -F32 -n "EFIBOOT" ${partition2}
    mkfs.ext4 -L ROOT ${partition3}
    mount -t ext4 ${partition3} /mnt
elif [[ "${FS}" == "luks" ]]; then
    mkfs.vfat -F32 -n "EFIBOOT" ${partition2}
    echo -n "${LUKS_PASSWORD}" | cryptsetup -y -v luksFormat ${partition3} -
    echo -n "${LUKS_PASSWORD}" | cryptsetup open ${partition3} ROOT -
    mkfs.btrfs -L ROOT ${partition3}
    mount -t btrfs ${partition3} /mnt
    subvolumesetup
    echo ENCRYPTED_PARTITION_UUID=$(blkid -s UUID -o value ${partition3}) >> $CONFIGS_DIR/setup.conf
fi

mkdir -p /mnt/boot/efi
mount -t vfat -L EFIBOOT /mnt/boot/

if ! grep -qs '/mnt' /proc/mounts; then
    echo "Drive is not mounted can not continue"
    echo "Rebooting in 3 Seconds ..." && sleep 1
    echo "Rebooting in 2 Seconds ..." && sleep 1
    echo "Rebooting in 1 Second ..." && sleep 1
    reboot now
fi

pacstrap /mnt base base-devel linux linux-firmware vim nano sudo archlinux-keyring wget libnewt --noconfirm --needed
echo "keyserver hkp://keyserver.ubuntu.com" >> /mnt/etc/pacman.d/gnupg/gpg.conf
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

genfstab -L /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab
if [[ ! -d "/sys/firmware/efi" ]]; then
    grub-install --boot-directory=/mnt/boot ${DISK}
else
    pacstrap /mnt efibootmgr --noconfirm --needed
fi

TOTAL_MEM=$(cat /proc/meminfo | grep -i 'memtotal' | grep -o '[[:digit:]]*')
if [[  $TOTAL_MEM -lt 8000000 ]]; then
    mkdir -p /mnt/opt/swap
    chattr +C /mnt/opt/swap
    dd if=/dev/zero of=/mnt/opt/swap/swapfile bs=1M count="$SWAPSIZE" status=progress
    chmod 600 /mnt/opt/swap/swapfile
    chown root /mnt/opt/swap/swapfile
    mkswap /mnt/opt/swap/swapfile
    swapon /mnt/opt/swap/swapfile
    echo "/opt/swap/swapfile	none	swap	sw	0	0" >> /mnt/etc/fstab
fi
MAIN

arch-chroot /mnt /bin/bash << BASE 1> setup.log
#!/usr/bin/env bash

pacman -S --noconfirm --needed networkmanager dhclient pacman-contrib curl reflector rsync grub arch-install-scripts git
systemctl enable --now NetworkManager
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak

if [[  $(cat /proc/meminfo | grep -i 'memtotal' | grep -o '[[:digit:]]*') -gt 8000000 ]]; then
sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(grep -c ^processor /proc/cpuinfo)\"/g" /etc/makepkg.conf
sed -i "s/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T $(grep -c ^processor /proc/cpuinfo) -z -)/g" /etc/makepkg.conf
fi

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
timedatectl --no-ask-password set-timezone ${TIMEZONE}
timedatectl --no-ask-password set-ntp 1
localectl --no-ask-password set-locale LANG="en_US.UTF-8" LC_TIME="en_US.UTF-8"
ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
localectl --no-ask-password set-keymap ${KEYMAP}
sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm --needed

if [[ -n "$PACKAGES" ]]; then
    sudo pacman -S --noconfirm --needed <( curl -s -L $PACKAGES ) || sudo pacman -S --noconfirm --needed <- $PACKAGES
else
    sudo pacman -S --noconfirm --needed gnome gnome-extra
    # sudo pacman -S --noconfirm --needed - < pkgfile.txt
fi

# determine processor type and install microcode
proc_type=$( lscpu )
if grep -E "GenuineIntel" <<< ${proc_type}; then
    echo "Installing Intel microcode"
    pacman -S --noconfirm --needed intel-ucode
    proc_ucode=intel-ucode.img
elif grep -E "AuthenticAMD" <<< ${proc_type}; then
    echo "Installing AMD microcode"
    pacman -S --noconfirm --needed amd-ucode
    proc_ucode=amd-ucode.img
fi

gpu_type=$( lspci )
if grep -E "NVIDIA|GeForce" <<< ${gpu_type}; then
    pacman -S --noconfirm --needed nvidia
	nvidia-xconfig
elif lspci | grep 'VGA' | grep -E "Radeon|AMD"; then
    pacman -S --noconfirm --needed xf86-video-amdgpu
elif grep -E "Integrated Graphics Controller" <<< ${gpu_type}; then
    pacman -S --noconfirm --needed libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa
elif grep -E "Intel Corporation UHD" <<< ${gpu_type}; then
    pacman -S --needed --noconfirm libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa
fi


if [ $( whoami ) = "root"  ]; then
    groupadd libvirt
    useradd -m -G wheel,libvirt -s /bin/bash $USERNAME
    echo "$USERNAME:$PASSWORD" | chpasswd
	echo $NAME_OF_MACHINE > /etc/hostname
else
	echo "You are already a user proceed with aur installs"
fi
if [[ ${FS} == "luks" ]]; then
    sed -i 's/filesystems/encrypt filesystems/g' /etc/mkinitcpio.conf
    mkinitcpio -p linux
fi
BASE


arch-chroot /mnt /usr/bin/runuser -u $USERNAME -- << PACKAGES 1> packages.log


# git clone "https://aur.archlinux.org/$AUR_HELPER.git"
# cd ~/$AUR_HELPER
# makepkg -si --noconfirm
if [[ -n "$CUSTOM_SCRIPT" ]]; then
    bash <( curl $CUSTOM_SCRIPT ) || bash $CUSTOM_SCRIPT
fi
PACKAGES

arch-chroot /mnt /bin/bash << POST

if [[ -d "/sys/firmware/efi" ]]; then
    grub-install --efi-directory=/boot ${DISK}
fi

if [[ "${FS}" == "luks" ]]; then
sed -i "s%GRUB_CMDLINE_LINUX_DEFAULT=\"%GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=${ENCRYPTED_PARTITION_UUID}:ROOT root=/dev/mapper/ROOT %g" /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg

if [[ ${DESKTOP_ENV} == "kde" ]]; then
  systemctl enable sddm.service

elif [[ "${DESKTOP_ENV}" == "gnome" ]]; then
  systemctl enable gdm.service

elif [[ "${DESKTOP_ENV}" == "lxde" ]]; then
  systemctl enable lxdm.service

else
  if [[ ! "${INSTALL_TYPE}" == "server"  ]]; then
  sudo pacman -S --noconfirm --needed lightdm lightdm-gtk-greeter
  systemctl enable lightdm.service
  fi
fi

systemctl enable cups.service
ntpd -qg
systemctl enable ntpd.service
systemctl disable dhcpcd.service
systemctl stop dhcpcd.service
systemctl enable NetworkManager.service
systemctl enable bluetooth
systemctl enable avahi-daemon.service

sed -i 's/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL/# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

POST

[[ "${LOGS}" == "yes" ]] && cp -v *.log /mnt/home/$USERNAME

for i in {0..7}; do
tput setaf $i bold
echo "Arch install finished. Check the logs."
done
tput sgr0
