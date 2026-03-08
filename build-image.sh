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
GENIMAGE_PATH=$(realpath "${REALPATH_BASE_DIR}/embedded_quickstart/genimage.sh")
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

VERSION_TAG="$1"
echo "Version tag: ${VERSION_TAG}"

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

#TARFILE=$(ls "${IMAGE_DIR}" 2>/dev/null | head -n1 || true)
#if [ ! -n "$TARFILE" ]; then
#	echo "No rootfs archive found in /tmp/rootfs"
#	exit
#fi

# placeholder to kick off the x86_64 detection of the script
touch "${IMAGE_DIR}/grub-efi-bootx64.efi"

# Build the image properly
bash "$GENIMAGE_PATH" "${IMAGE_DIR}" "${SYSTEM_NAME}-${VERSION}"

echo "current directory:"
ls -lah .

# Remove the empty sentinel file used for x86_64 detection
rm -f "${IMAGE_DIR}/grub-efi-bootx64.efi"

# BTRFS rootfs subvolume
readonly SUBVOLUME_FILE=$(find "${OUTPUT_DIR}" -name '*.btrfs.xz' 2>/dev/null | head -n1)
if [ ! -f "${SUBVOLUME_FILE}" ]; then
	echo "No BTRFS subvolume file found in ${IMAGE_DIR}"
	exit 1
fi

# Update package filename
readonly UPDATE_FILE=$(find "${OUTPUT_DIR}" -name 'update_package.tar' 2>/dev/null | head -n1)
if [ ! -f "${UPDATE_FILE}" ]; then
	echo "No update file found in ${IMAGE_DIR}"
	exit 1
fi

echo "Binary dir"
ls -lah ${IMAGE_DIR}

mv "${IMAGE_DIR}/disk_image.img" "disk_image_${SYSTEM_NAME}-${VERSION}.img"

# cleanup any leftover rootfs tars
rm -f ${IMAGE_DIR}/*rootfs*.tar*

# compress the resulting image
xz -9e --threads=0 "disk_image_${SYSTEM_NAME}-${VERSION}.img"
IMG_FILENAME="disk_image_${SYSTEM_NAME}-${VERSION}.img.xz"

sha256sum "$IMG_FILENAME" > sha256sum.txt
sha256sum "$UPDATE_FILE" >> sha256sum.txt
sha256sum "$SUBVOLUME_FILE" >> sha256sum.txt
cat sha256sum.txt

# Move the image and other artifacts to the output directory, if one was specified.
safe_mv() {
	src="$1"
	dest_dir="$2"
	[ -f "$src" ] || return 0
	dest="$dest_dir/$(basename "$src")"
	src_abs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
	dest_dir_abs="$(cd "${dest_dir}" 2>/dev/null && pwd || echo "${dest_dir}")"
	dest_abs="${dest_dir_abs}/$(basename "$src")"
	if [ "$src_abs" = "$dest_abs" ]; then
		echo "Skipping move; source and destination are identical: $src_abs"
		return 0
	fi
	mkdir -p "$dest_dir"
	mv "$src" "$dest"
}

safe_mv "${UPDATE_FILE}" "${OUTPUT_DIR}"
safe_mv "${SUBVOLUME_FILE}" "${OUTPUT_DIR}"
safe_mv "${IMG_FILENAME}" "${OUTPUT_DIR}"
safe_mv "${IMAGE_DIR}/build_info.txt" "${OUTPUT_DIR}"
safe_mv "build_info.txt" "${OUTPUT_DIR}"
safe_mv "sha256sum.txt" "${OUTPUT_DIR}"
safe_mv "container.txt" "${OUTPUT_DIR}"

# Debugging info
ls -lah "${OUTPUT_DIR}"

# set outputs for github actions
if [ -f "${GITHUB_OUTPUT:-}" ]; then
	readonly UPDATE_FILENAME=$(basename "${UPDATE_FILE}")
	readonly DISK_FILENAME=$(basename "${IMG_FILENAME}")
	readonly SUBVOL_FILENAME=$(basename "${SUBVOLUME_FILE}")
	echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
	echo "display_version=${DISPLAY_VERSION}" >> "${GITHUB_OUTPUT}"
	echo "display_name=${SYSTEM_DESC}" >> "${GITHUB_OUTPUT}"
	echo "disk_image_filename=${DISK_FILENAME}" >> "${GITHUB_OUTPUT}"
	echo "update_image_filename=${SUBVOL_FILENAME}" >> "${GITHUB_OUTPUT}"
	echo "update_filename=${UPDATE_FILENAME}" >> "${GITHUB_OUTPUT}"
else
	echo "No github output file set"
fi
