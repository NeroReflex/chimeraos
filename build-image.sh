#! /bin/bash

set -euo pipefail
set -x

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be run as root"
	exit 1
fi

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
fi

source ./manifest

if [ -z "${SYSTEM_NAME:-}" ]; then
  echo "SYSTEM_NAME must be specified"
  exit
fi

if [ -z "${VERSION:-}" ]; then
  echo "VERSION must be specified"
  exit
fi

DISPLAY_VERSION=${VERSION:-}
VERSION_NUMBER=${VERSION:-}

# If a prebuilt rootfs tar was provided (downloaded into /tmp/rootfs by the workflow),
# extract it directly into the btrfs subvolume, otherwise error out
if [ ! -d /tmp/rootfs ]; then
	echo "No prebuilt rootfs found"
	exit
fi

ls -lah /tmp/rootfs

OUTPUT_DIR=${OUTPUT_DIR:-}
if [ -n "${OUTPUT_DIR:-}" ]; then
	mkdir -p "${OUTPUT_DIR}"
	mv /tmp/rootfs/* "${OUTPUT_DIR}"
	readonly IMAGE_DIR="${OUTPUT_DIR}"
else
#	echo "No output directory specified, skipping moving rootfs"
#	readonly IMAGE_DIR="/tmp/rootfs"
	echo "No output directory specified, moving rootfs to /output"
	mkdir -p /output
	mv /tmp/rootfs/* /output
	readonly IMAGE_DIR="/output"
	OUTPUT_DIR="/output"
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

echo "current directory:"
ls -lah .

echo "Binary dir"
ls -lah ${IMAGE_DIR}

mv "${IMAGE_DIR}/disk_image.img" "disk_image_${SYSTEM_NAME}-${VERSION}.img"

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
	#mv "${IMAGE_DIR}/build_info.txt" "${OUTPUT_DIR}/"
	#mv "sha256sum.txt" "${OUTPUT_DIR}/"
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
