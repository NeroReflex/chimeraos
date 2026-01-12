#! /bin/bash

set -euo pipefail
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
VERSION_NUMBER=${VERSION}

if [ -n "$1" ]; then
	DISPLAY_VERSION="${VERSION} (${1})"
	VERSION="${VERSION}_${1}"
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

# If a prebuilt rootfs tar was provided (downloaded into /tmp/rootfs by the workflow),
# extract it directly into the btrfs subvolume, otherwise error out
if [ ! -d /tmp/rootfs ]; then
	echo "No prebuilt rootfs found"
	exit
fi

ls -lah /tmp/rootfs

TARFILE=$(ls /tmp/rootfs 2>/dev/null | head -n1 || true)
if [ -n "$TARFILE" ]; then
	echo "Found rootfs archive: /tmp/rootfs/$TARFILE — extracting into ${BUILD_PATH}"
	# Use -a so tar auto-detects compression from suffix
	tar -xaf /tmp/rootfs/$TARFILE -C ${BUILD_PATH}
else
	echo "No rootfs archive found in /tmp/rootfs"
	exit
fi

# When rootfs tar was used, ensure package folders exist inside the build path
mkdir -p ${BUILD_PATH}/local_pkgs
mkdir -p ${BUILD_PATH}/aur_pkgs
mkdir -p ${BUILD_PATH}/override_pkgs
cp -R manifest ${BUILD_PATH}/ || true
cp -rv aur-pkgs/*.pkg.tar* ${BUILD_PATH}/aur_pkgs || true
cp -rv pkgs/*.pkg.tar* ${BUILD_PATH}/local_pkgs || true
if [ -n "${PACKAGE_OVERRIDES:-}" ]; then
	wget --directory-prefix=${BUILD_PATH}/override_pkgs ${PACKAGE_OVERRIDES} || true
fi

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
umount -l ${MOUNT_PATH}
rm -rf ${MOUNT_PATH}
rm -rf ${BUILD_IMG}

IMG_FILENAME="${SYSTEM_NAME}-${VERSION}.img.tar.xz"
if [ -z "${NO_COMPRESS:-}" ]; then
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
	if [ -n "${OUTPUT_DIR:-}" ]; then
		mkdir -p "${OUTPUT_DIR}"
		mv "${IMG_FILENAME}" "${OUTPUT_DIR}/"
		mv "build_info.txt" "${OUTPUT_DIR}/"
		mv "sha256sum.txt" "${OUTPUT_DIR}/"
	fi

	# set outputs for github actions
	if [ -f "${GITHUB_OUTPUT:-}" ]; then
		echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
		echo "display_version=${DISPLAY_VERSION}" >> "${GITHUB_OUTPUT}"
		echo "display_name=${SYSTEM_DESC}" >> "${GITHUB_OUTPUT}"
		echo "image_filename=${IMG_FILENAME}" >> "${GITHUB_OUTPUT}"
	else
		echo "No github output file set"
	fi
else
	echo "Local build, output IMG directly"
	if [ -n "${OUTPUT_DIR:-}" ]; then
		mkdir -p "${OUTPUT_DIR}"
		mv ${SYSTEM_NAME}-${VERSION}.img ${OUTPUT_DIR}
	fi
fi
