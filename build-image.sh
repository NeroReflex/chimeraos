#! /bin/bash

set -e
set -x

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be run as root"
	exit 1
fi

BUILD_USER=${BUILD_USER:-}
OUTPUT_DIR=${OUTPUT_DIR:-}


source manifest

if [ -z "${SYSTEM_NAME}" ]; then
  echo "SYSTEM_NAME must be specified"
  exit
fi

if [ -z "${VERSION}" ]; then
  echo "VERSION must be specified"
  exit
fi

DISPLAY_VERSION=${VERSION}
LSB_VERSION=${VERSION}
VERSION_NUMBER=${VERSION}

if [ -n "$1" ]; then
	DISPLAY_VERSION="${VERSION} (${1})"
	VERSION="${VERSION}_${1}"
	LSB_VERSION="${LSB_VERSION}　(${1})"
	BUILD_ID="${1}"
fi

MOUNT_PATH=/tmp/${SYSTEM_NAME}-build
BUILD_PATH=${MOUNT_PATH}/subvolume
SNAP_PATH=${MOUNT_PATH}/${SYSTEM_NAME}-${VERSION}
BUILD_IMG=/output/${SYSTEM_NAME}-build.img

mkdir -p ${MOUNT_PATH}

fallocate -l ${SIZE} ${BUILD_IMG}
mkfs.btrfs -f ${BUILD_IMG}
mount -t btrfs -o loop,compress-force=zstd:15 ${BUILD_IMG} ${MOUNT_PATH}
btrfs subvolume create ${BUILD_PATH}

# copy the makepkg.conf into chroot
cp /etc/makepkg.conf rootfs/etc/makepkg.conf

# bootstrap using our configuration
pacstrap -K -C rootfs/etc/pacman.conf ${BUILD_PATH}

# copy the builder mirror list into chroot
mkdir -p rootfs/etc/pacman.d
cp /etc/pacman.d/mirrorlist rootfs/etc/pacman.d/mirrorlist

# copy files into chroot
cp -R manifest rootfs/. ${BUILD_PATH}/

mkdir ${BUILD_PATH}/local_pkgs
mkdir ${BUILD_PATH}/aur_pkgs
mkdir ${BUILD_PATH}/override_pkgs

cp -rv aur-pkgs/*.pkg.tar* ${BUILD_PATH}/aur_pkgs
cp -rv pkgs/*.pkg.tar* ${BUILD_PATH}/local_pkgs

if [ -n "${PACKAGE_OVERRIDES}" ]; then
	wget --directory-prefix=${BUILD_PATH}/override_pkgs ${PACKAGE_OVERRIDES}
fi


# chroot into target
mount --bind ${BUILD_PATH} ${BUILD_PATH}
arch-chroot ${BUILD_PATH} /bin/bash <<EOF
set -e
set -x

# This will prevent frzr bootloader from erroring when installing kernels
# due to the pacman hook being executed at kernel-install time
export FRZR_IMAGE_GENERATION=1

source /manifest

pacman-key --populate

echo "LANG=en_US.UTF-8" > /etc/locale.conf
locale-gen

# Disable parallel downloads
sed -i '/ParallelDownloads/s/^/#/g' /etc/pacman.conf

# Cannot check space in chroot
sed -i '/CheckSpace/s/^/#/g' /etc/pacman.conf

# update package databases
pacman --noconfirm -Syy

# Avoid mkintcpio being auto-installed while installing the kernel (we want dracut)
pacman -S --noconfirm dracut
# Disable check and debug for makepkg on the final image
sed -i '/BUILDENV/s/ check/ !check/g' /etc/makepkg.conf
sed -i '/OPTIONS/s/ debug/ !debug/g' /etc/makepkg.conf

# install kernel package
if [ "$KERNEL_PACKAGE_ORIGIN" == "local" ] ; then
	pacman --noconfirm -U --overwrite '*' \
	/override_pkgs/${KERNEL_PACKAGE}-*.pkg.tar.zst
else
	pacman --noconfirm -S "${KERNEL_PACKAGE}" "${KERNEL_PACKAGE}-headers"
fi

# install local packages
pacman --noconfirm -U --overwrite '*' /local_pkgs/*
rm -rf /var/cache/pacman/pkg

# remove jack2 to prevent conflict with pipewire-jack
pacman --noconfirm -Rdd jack2 || true

# install packages
pacman --noconfirm -S --overwrite '*' --disable-download-timeout ${PACKAGES}
rm -rf /var/cache/pacman/pkg

# install AUR packages
pacman --noconfirm -U --overwrite '*' /aur_pkgs/*
rm -rf /var/cache/pacman/pkg

# install override packages
pacman --noconfirm -U --overwrite '*' /override_pkgs/*
rm -rf /var/cache/pacman/pkg

# Install the new iptables
# See https://gitlab.archlinux.org/archlinux/packaging/packages/iptables/-/issues/1
# Since base package group adds iptables by default
# pacman will ask for confirmation to replace that package
# but the default answer is no.
# doing yes | pacman omitting --noconfirm is a necessity 
yes | pacman -S iptables-nft

# enable services
systemctl enable ${SERVICES}

# enable user services
systemctl --global enable ${USER_SERVICES}

# disable root login
passwd --lock root

# add root to the frzr group
sudo usermod -a -G frzr root

# create user
groupadd -r autologin
useradd -m ${USERNAME} -G autologin,wheel,plugdev,frzr
echo "${USERNAME}:${USERNAME}" | chpasswd

# set the default editor, so visudo works
echo "export EDITOR=/usr/bin/vim" >> /etc/bash.bashrc

echo "[Seat:*]
autologin-user=${USERNAME}
" > /etc/lightdm/lightdm.conf.d/00-autologin-user.conf

echo "${SYSTEM_NAME}" > /etc/hostname

# enable multicast dns in avahi
sed -i "/^hosts:/ s/resolve/mdns resolve/" /etc/nsswitch.conf

# configure ssh
echo "
AuthorizedKeysFile	.ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PrintMotd no # pam does that
Subsystem	sftp	/usr/lib/ssh/sftp-server
" > /etc/ssh/sshd_config

# Write the fstab file
# NOTE: gid=379 is the group ID of the frzr group
# WARNING: mounting partitions using LABEL exposes us to a bug where multiple disks cannot have frzr systems and how to solve this still is an open question
echo "
LABEL=frzr_efi           /efi       vfat      uid=0,gid=379,fmask=0077,dmask=0077,rw,noatime,nofail                                                                                                                                                                                                                                                                                                                                                               0   2
LABEL=frzr_root          /frzr_root btrfs     defaults,x-initrd.mount,subvolid=5,rw,noatime                                                                                                                                                                                                                                                                                                                                                                       0   2
LABEL=frzr_root          /home      btrfs     defaults,x-systemd.rw-only,subvol=/home,rw,noatime,nofail                                                                                                                                                                                                                                                                                                                                                           0   0
overlay                  /root      overlay   defaults,x-systemd.requires-mounts-for=/frzr_root,x-systemd.requires-mounts-for=/sysroot/frzr_root,x-initrd.mount,lowerdir=/sysroot/root,upperdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/root_overlay/upperdir,workdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/root_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,comment=rootoverlay               0   0
overlay                  /boot      overlay   defaults,x-systemd.requires-mounts-for=/frzr_root,x-systemd.requires-mounts-for=/sysroot/frzr_root,x-initrd.mount,lowerdir=/sysroot/boot,upperdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/boot_overlay/upperdir,workdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/boot_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,comment=bootoverlay               0   0
overlay                  /usr       overlay   defaults,x-systemd.requires-mounts-for=/frzr_root,x-systemd.requires-mounts-for=/sysroot/frzr_root,x-initrd.mount,lowerdir=/sysroot/usr,upperdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/usr_overlay/upperdir,workdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/usr_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,comment=usroverlay                   0   0
overlay                  /etc       overlay   defaults,x-systemd.requires-mounts-for=/frzr_root,x-systemd.requires-mounts-for=/sysroot/frzr_root,x-initrd.mount,x-systemd.rw-only,lowerdir=/sysroot/etc,upperdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/etc_overlay/upperdir,workdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/etc_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,comment=etcoverlay 0   0
overlay                  /var       overlay   defaults,x-systemd.requires-mounts-for=/frzr_root,x-systemd.requires-mounts-for=/sysroot/frzr_root,x-initrd.mount,x-systemd.rw-only,lowerdir=/sysroot/var,upperdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/var_overlay/upperdir,workdir=/sysroot/frzr_root/deployments_data/${SYSTEM_NAME}-${VERSION}/var_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,comment=varoverlay 0   0
/frzr_root/swap/swapfile none       swap      sw                                                                                                                                                                                                                                                                                                                                                                                                                  0   0
" > /etc/fstab

echo "
LSB_VERSION=1.4
DISTRIB_ID=${SYSTEM_NAME}
DISTRIB_RELEASE=\"${LSB_VERSION}\"
DISTRIB_DESCRIPTION=${SYSTEM_DESC}
" > /etc/lsb-release

echo 'NAME="${SYSTEM_DESC}"
VERSION="${DISPLAY_VERSION}"
VERSION_ID="${VERSION_NUMBER}"
BUILD_ID="${BUILD_ID}"
PRETTY_NAME="${SYSTEM_DESC} ${DISPLAY_VERSION}"
ID=${SYSTEM_NAME}
ID_LIKE=arch
ANSI_COLOR="1;31"
HOME_URL="${WEBSITE}"
DOCUMENTATION_URL="${DOCUMENTATION_URL}"
BUG_REPORT_URL="${BUG_REPORT_URL}"' > /usr/lib/os-release

# install extra certificates
trust anchor --store /extra_certs/*.crt

# run post install hook
postinstallhook

# record installed packages & versions
pacman -Q > /manifest

# preserve installed package database
mkdir -p /usr/var/lib/
mv /var/lib/pacman /usr/var/lib/

# Remove the fallback: it is never used and takes up space
if [ -e "/boot/initramfs-${KERNEL_PACKAGE}-fallback.img" ]; then
	rm "/boot/initramfs-${KERNEL_PACKAGE}-fallback.img"
fi

# Since frzr pre-v1.0.0 has an hardcoded cp of /boot/vmlinuz-linux and /boot/initramfs-linux.img
# create two empty files so that the cp command won't fail: these will be  replaced by a migration hook.
#
# Note: The following is kept for compatibility with older frzr
# 		This can safely be removed when the compatibility with
# 		frzr pre-v1.0.0 will be dropped
if [ "${KERNEL_PACKAGE}" = "linux" ]; then
	echo "Kernel is named 'linux' nothing to do."
else
	touch /boot/vmlinuz-linux
	touch /boot/initramfs-linux.img
fi

# clean up/remove unnecessary files
# Keep every file in /var except for logs (populated by GitHub CI)
# the pacman database: it was backed up to another location and
# will be restored by an unlock hook
rm -rf \
/local_pkgs \
/aur_pkgs \
/override_pkgs \
/extra_certs \
/home \
/var/log \
/var/lib/pacman/local \

# create necessary directories
mkdir -p /home
mkdir -p /frzr_root
mkdir -p /efi
mkdir -p /var/log
EOF

#defrag the image
btrfs filesystem defragment -r ${BUILD_PATH}

# copy files into chroot again
cp -R rootfs/. ${BUILD_PATH}/
rm -rf ${BUILD_PATH}/extra_certs

echo "${SYSTEM_NAME}-${VERSION}" > ${BUILD_PATH}/build_info
echo "" >> ${BUILD_PATH}/build_info
cat ${BUILD_PATH}/manifest >> ${BUILD_PATH}/build_info
rm ${BUILD_PATH}/manifest

# freeze archive date of build to avoid package drift on unlock
# if no archive date is set
if [ -z "${ARCHIVE_DATE}" ]; then
	export TODAY_DATE=$(date +%Y/%m/%d)
	echo "Server=https://archive.archlinux.org/repos/${TODAY_DATE}/\$repo/os/\$arch" > \
	${BUILD_PATH}/etc/pacman.d/mirrorlist
fi

btrfs subvolume snapshot -r ${BUILD_PATH} ${SNAP_PATH}
btrfs send -f ${SYSTEM_NAME}-${VERSION}.img ${SNAP_PATH}

cp ${BUILD_PATH}/build_info build_info.txt

# clean up
umount -l ${BUILD_PATH}
umount -l ${MOUNT_PATH}
rm -rf ${MOUNT_PATH}
rm -rf ${BUILD_IMG}

IMG_FILENAME="${SYSTEM_NAME}-${VERSION}.img.tar.xz"
if [ -z "${NO_COMPRESS}" ]; then
	# This can be used only when installing from the refactored frzr
	# Maximizes the github building space and makes the build faster
	#
	# Remember to remove the "btrfs send -f ${SYSTEM_NAME}-${VERSION}.img ${SNAP_PATH}" line
	# alongside with this commend when implemented.
	#
	# btrfs send ${SNAP_PATH} | xz -9e --memory=95% -T0 > ${IMG_FILENAME}
	# 
	# When implementing this remember to change $IMG_FILENAME extension to .img.xz
	tar -c -I'xz -9e --verbose -T4' -f ${IMG_FILENAME} ${SYSTEM_NAME}-${VERSION}.img
	rm -f ${SYSTEM_NAME}-${VERSION}.img

	sha256sum "$IMG_FILENAME" > sha256sum.txt
	cat sha256sum.txt

	# Move the image to the output directory, if one was specified.
	if [ -n "${OUTPUT_DIR}" ]; then
		mkdir -p "${OUTPUT_DIR}"
		mv ${IMG_FILENAME} ${OUTPUT_DIR}
		mv build_info.txt ${OUTPUT_DIR}
		mv sha256sum.txt ${OUTPUT_DIR}
	fi

	# set outputs for github actions
	if [ -f "${GITHUB_OUTPUT}" ]; then
		echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
		echo "display_version=${DISPLAY_VERSION}" >> "${GITHUB_OUTPUT}"
		echo "display_name=${SYSTEM_DESC}" >> "${GITHUB_OUTPUT}"
		echo "image_filename=${IMG_FILENAME}" >> "${GITHUB_OUTPUT}"
	else
		echo "No github output file set"
	fi
else
	echo "Local build, output IMG directly"
	if [ -n "${OUTPUT_DIR}" ]; then
		mkdir -p "${OUTPUT_DIR}"
		mv ${SYSTEM_NAME}-${VERSION}.img ${OUTPUT_DIR}
	fi
fi
