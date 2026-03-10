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

# Copy the public key file
cp -v public_key_pkcs1.pem "${deployment_rootfs_dir}/usr/share/embuer/"

# Create the settings file
readonly SETTINGS_FILE_PATH="${deployment_rootfs_dir}/usr/share/embuer/config.json"
mkdir -p "${deployment_rootfs_dir}/usr/share/embuer/"
echo "{" > "${SETTINGS_FILE_PATH}"
echo "  \"update_url\": \"http://65.21.79.97/update_package.tar\"," >> "${SETTINGS_FILE_PATH}"
echo "  \"auto_install_updates\": false," >> "${SETTINGS_FILE_PATH}"
echo "" >> "${SETTINGS_FILE_PATH}"
echo "  \"rootfs_dir\": \"/mnt\"," >> "${SETTINGS_FILE_PATH}"
echo "" >> "${SETTINGS_FILE_PATH}"
echo "  \"public_key_pem\": \"/usr/share/embuer/public_key_pkcs1.pem\"" >> "${SETTINGS_FILE_PATH}"
echo "}" >> "${SETTINGS_FILE_PATH}"

# Create the manifest file for the deployment
mkdir -p "${deployment_rootfs_dir}/usr/share/embuer"
readonly MANIFEST_FILE_PATH="${deployment_rootfs_dir}/usr/share/embuer/manifest.json"
echo "{" > "${MANIFEST_FILE_PATH}"
echo "    \"version\": \"$deployment_name\"," >> "${MANIFEST_FILE_PATH}"
echo "    \"readonly\": true" >> "${MANIFEST_FILE_PATH}"
echo "}" >> "${MANIFEST_FILE_PATH}"

find "$deployment_rootfs_dir/usr" -name "vmlinu*"

readonly KERNEL_FILE=$(find "$deployment_rootfs_dir/usr" -name "vmlinu*" | head -n 1)
if [ -f "$KERNEL_FILE" ]; then
    echo "Found kernel file '${KERNEL_FILE}': making it bootable"
    ln "$KERNEL_FILE" "$deployment_rootfs_dir/boot/bzImage"
else
    echo "No kernel file found in ${deployment_rootfs_dir}/usr"
    exit -1
fi
