#!/bin/bash

# Make embuer-specific changes to the image to make it a valid and bootable deployment.
# It can be executed by embuer-installer whith the --manual-script option.

readonly deployment_name="$1"
readonly deployment_rootfs_dir="$2"
readonly deployment_rootfs_data_dir="$3"

echo "Creating deployment $deployment_name on $deployment_rootfs_dir with data dir $deployment_rootfs_data_dir"

echo "Searching for the rootfs..."
readonly ROOTFS_TAR_FILE=$(find "${BINARIES_DIR}" -name '*rootfs*.tar*' | head -n 1)
if [ -f "${ROOTFS_TAR_FILE}" ]; then
    echo "Unpacking '${ROOTFS_TAR_FILE}' on the deployment subvolume..."
    tar xpf "${ROOTFS_TAR_FILE}" -C "${deployment_rootfs_dir}"
else
    echo "No tar rootfs found."
    exit -1
fi

# Create the manifest file for the deployment.
mkdir -p $deployment_rootfs_dir/usr/share/embuer
echo "{" > $deployment_rootfs_dir/usr/share/embuer/manifest.json
echo "    \"version\": \"$deployment_name\"," >> $deployment_rootfs_dir/usr/share/embuer/manifest.json
echo "    \"readonly\": true" >> $deployment_rootfs_dir/usr/share/embuer/manifest.json
echo "}" >> $deployment_rootfs_dir/usr/share/embuer/manifest.json

find "$deployment_rootfs_dir/usr" -name "vmlinu*"

readonly KERNEL_FILE=$(find "$deployment_rootfs_dir/usr" -name "vmlinu*" | head -n 1)
if [ -f "$KERNEL_FILE" ]; then
    echo "Found kernel file '${KERNEL_FILE}': making it bootable"
    ln "$KERNEL_FILE" "$deployment_rootfs_dir/boot/bzImage"
else
    echo "No kernel file found in ${deployment_rootfs_dir}/usr"
    exit -1
fi
