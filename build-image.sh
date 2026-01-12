#! /bin/bash

set -euo pipefail
set -x

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be run as root"
	exit 1
fi

BUILD_USER=${BUILD_USER:-}
OUTPUT_DIR=${OUTPUT_DIR:-}

readonly BASE_DIR=$(pwd)
readonly REALPATH_BASE_DIR=$(realpath "${BASE_DIR}")

git clone https://github.com/NeroReflex/embedded_quickstart.git
pushd embedded_quickstart
git checkout scarthgap
popd

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

# If a prebuilt rootfs tar was provided (downloaded into /tmp/rootfs by the workflow),
# extract it directly into the btrfs subvolume, otherwise error out
if [ ! -d /tmp/rootfs ]; then
	echo "No prebuilt rootfs found"
	exit
fi

ls -lah /tmp/rootfs

TARFILE=$(ls /tmp/rootfs 2>/dev/null | head -n1 || true)
if [ ! -n "$TARFILE" ]; then
	echo "No rootfs archive found in /tmp/rootfs"
	exit
fi

# placeholder to kick off the x86_64 detection of the script
touch "grub-efi-bootx64.efi"

# Build the image properly
bash "${REALPATH_BASE_DIR}/embedded_quickstart/genimage.sh" "/tmp/rootfs" "${SYSTEM_NAME}-${VERSION}"

mv "disk_image.img" "disk_image_${SYSTEM_NAME}-${VERSION}.img"
xz -9e --threads=0 "disk_image_${SYSTEM_NAME}-${VERSION}.img"
IMG_FILENAME="disk_image_${SYSTEM_NAME}-${VERSION}.img.xz"

ls -lah .

sha256sum "$IMG_FILENAME" > sha256sum.txt
cat sha256sum.txt

# Move the image to the output directory, if one was specified.
if [ -n "${OUTPUT_DIR:-}" ]; then
	mkdir -p "${OUTPUT_DIR}"
	mv "${IMG_FILENAME}" "${OUTPUT_DIR}/"
	mv "build_info.txt" "${OUTPUT_DIR}/"
	mv "sha256sum.txt" "${OUTPUT_DIR}/"
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
	echo "No github output file set"
fi
