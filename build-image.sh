#! /bin/bash

set -euo pipefail
set -x

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be run as root"
	exit 1
fi

OUTPUT_DIR=${OUTPUT_DIR:-}

# Install needed software
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y \
	git wget curl coreutils util-linux dos2unix bsdmainutils \
	btrfs-progs dosfstools mtools parted \
	lsb-release \
	gzip zstd xz-utils \
	libelf-dev efitools libnss3-tools pesign \
	policycoreutils mount efitools libnss3-tools uuid-runtime syslinux-utils

readonly BASE_DIR=$(pwd)
readonly REALPATH_BASE_DIR=$(realpath "${BASE_DIR}")

git clone https://github.com/NeroReflex/embedded_quickstart.git
pushd embedded_quickstart
git checkout scarthgap
popd

## Patch the cloned genimage.sh to ensure partition device nodes appear in
## containerized runners where udev may not auto-create "${LOOP}pN" nodes.
GENIMAGE_PATH="${REALPATH_BASE_DIR}/embedded_quickstart/genimage.sh"
if [ ! -x "${GENIMAGE_PATH}" ]; then
	echo "Making ${GENIMAGE_PATH} executable"
	chmod a+x "${GENIMAGE_PATH}"
#	echo "Patching ${GENIMAGE_PATH} to add partition-scan and detection fallback"
#	awk '
#	BEGIN{p=0}
#	/losetup .*--show/ && p==0 {
#		print
#		print "    # --- partition-scan + detection fallback (injected by build-image.sh) ---"
#			print "    # Ask kernel/udev to create partition device nodes; try several helpers"
#			print "    # Debug: show current device nodes and mappings so CI logs capture state"
#			print "    echo 'DEBUG: listing /dev entries after losetup:' >&2"
#			print "    ls -l /dev/loop* /dev/mapper/* 2>/dev/null >&2 || true"
#			print "    echo 'DEBUG: losetup -a output:' >&2"
#			print "    losetup -a 2>/dev/null >&2 || true"
#			print "    echo 'DEBUG: kpartx -l output for the image:' >&2"
#			print "    if command -v kpartx >/dev/null 2>&1; then kpartx -l \"${LOOPBACK_OUTPUT}\" 2>/dev/null >&2 || true; fi"
#			print "    echo 'DEBUG: dmesg tail (last 50 lines):' >&2"
#			print "    dmesg | tail -n 50 >&2 || true"
#		print "    if command -v partprobe >/dev/null 2>&1; then partprobe \"${LOOPBACK_OUTPUT}\" || true; fi"
#		print "    if command -v partx >/dev/null 2>&1; then partx -a \"${LOOPBACK_OUTPUT}\" || true; fi"
#		print "    if command -v kpartx >/dev/null 2>&1; then kpartx -a \"${LOOPBACK_OUTPUT}\" || true; fi"
#		print "    if command -v udevadm >/dev/null 2>&1; then udevadm settle || sleep 1; fi"
#		print ""
#		print "    # Find the correct partition device path; support /dev/loopNpX and /dev/mapper/loopNpX"
#		print "    if [ -b \"${LOOPBACK_OUTPUT}p${IMAGE_PART_NUMBER:-1}\" ]; then"
#		print "      LOOPBACK_DEV_PART=\"${LOOPBACK_OUTPUT}p${IMAGE_PART_NUMBER:-1}\""
#		print "    elif [ -b \"/dev/mapper/$(basename \"${LOOPBACK_OUTPUT}\")p${IMAGE_PART_NUMBER:-1}\" ]; then"
#		print "      LOOPBACK_DEV_PART=\"/dev/mapper/$(basename \"${LOOPBACK_OUTPUT}\")p${IMAGE_PART_NUMBER:-1}\""
#		print "    else"
#		print "      # try to discover via kpartx listing"
#		print "      if command -v kpartx >/dev/null 2>&1; then"
#		print "        MAPDEV=$(kpartx -l \"${LOOPBACK_OUTPUT}\" 2>/dev/null | awk '{print \"/dev/mapper/\"$1}' | head -n1 || true)"
#		print "        if [ -n \"$MAPDEV\" ] && [ -b \"$MAPDEV\" ]; then"
#		print "          LOOPBACK_DEV_PART=\"$MAPDEV\""
#		print "        fi"
#		print "      fi"
#		print "    fi"
#		print "    # if still not found, leave the original variable behavior to fail visibly"
#		print "    # --- end injected block ---"
#		p=1; next
#	}
#	{ print }
#	' "${GENIMAGE_PATH}" > "${GENIMAGE_PATH}.patched" && mv "${GENIMAGE_PATH}.patched" "${GENIMAGE_PATH}"
#	fi
fi

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

if [ -n "${OUTPUT_DIR:-}" ]; then
	mkdir -p "${OUTPUT_DIR}"
	mv /tmp/rootfs/* "${OUTPUT_DIR}"
	readonly IMAGE_DIR="${OUTPUT_DIR}"
else
	echo "No output directory specified, skipping moving rootfs"
	readonly IMAGE_DIR="/tmp/rootfs"
fi

TARFILE=$(ls "${IMAGE_DIR}" 2>/dev/null | head -n1 || true)
if [ ! -n "$TARFILE" ]; then
	echo "No rootfs archive found in /tmp/rootfs"
	exit
fi

# placeholder to kick off the x86_64 detection of the script
touch "${IMAGE_DIR}/grub-efi-bootx64.efi"

# Build the image properly
bash "${REALPATH_BASE_DIR}/embedded_quickstart/genimage.sh" "${IMAGE_DIR}" "${SYSTEM_NAME}-${VERSION}"

mv "disk_image.img" "disk_image_${SYSTEM_NAME}-${VERSION}.img"

# cleanup any leftover rootfs tars
rm -f ${IMAGE_DIR}/*rootfs*.tar*

# compress the resulting image
xz -9e --threads=0 "disk_image_${SYSTEM_NAME}-${VERSION}.img"
IMG_FILENAME="disk_image_${SYSTEM_NAME}-${VERSION}.img.xz"

sha256sum "$IMG_FILENAME" > sha256sum.txt
cat sha256sum.txt

# Debugging info
ls -lah .

# Move the image to the output directory, if one was specified.
if [ -n "${OUTPUT_DIR:-}" ]; then
	mkdir -p "${OUTPUT_DIR}"
	mv "${IMG_FILENAME}" "${OUTPUT_DIR}/"
	mv "${IMAGE_DIR}/build_info.txt" "${OUTPUT_DIR}/"
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
