#!/bin/bash
set -x
#set -eu pipefail

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

################################################################################################
# If polyauth is present configure pam to use it for authentication
################################################################################################

if [ -f "${deployment_rootfs_dir}/etc/pam.d/system-auth" ] && [ -f "${deployment_rootfs_dir}/usr/lib/security/pam_polyauth.so" ]; then
    echo "Found polyauth, configuring PAM..."

    sed -n '/^[[:space:]]*auth[[:space:]]/=' "${deployment_rootfs_dir}/etc/pam.d/system-auth" | tail -1 |   { read l; if [ -n "$l" ]; then sed -i.bak "$((l))a\-auth     sufficient pam_login_ng.so" "${deployment_rootfs_dir}/etc/pam.d/system-auth"; fi; }

    # TODO:

# sed -n '/^[[:space:]]*account[[:space:]]/=' file | tail -1 | \
#  { read l; if [ -n "$l" ]; then sed -i.bak "$((l))a\\
#-account  sufficient pam_login_ng.so" file; fi; }


#sed -n '/^[[:space:]]*session[[:space:]]/=' file | tail -1 | \
#  { read l; if [ -n "$l" ]; then sed -i.bak "$((l))a\\
#-session  optional   pam_login_ng.so" file; fi; }


else
    echo "No polyauth found, skipping PAM configuration"
fi

################################################################################################
# Create the two files /etc/rdtab and /etc/fstab to make the deployment usable
################################################################################################

readonly DEPLOYMENTS_DATA_DIR="deployments_data"

# since systemd wants to write /etc/machine-id before mounting things in /etc/fstab
# and missing /etc/machine-id means dbus-broker breaking if it is available,
# then configure atomrootfsinit to pre-mount /etc and /var
if [ -f "${deployment_rootfs_dir}/usr/bin/atomrootfsinit" ]; then
    # kernel auto-mounts /dev
    #echo "dev                   /mnt/dev  devtmpfs rw 0 0" > "${deployment_rootfs_dir}/etc/rdtab"

    echo "dev     /mnt/dev  devtmpfs rw 0 0" > "${deployment_rootfs_dir}/etc/rdtab"
    echo "proc    /mnt/proc proc     rw 0 0" >> "${deployment_rootfs_dir}/etc/rdtab"
    echo "sys     /mnt/sys  sysfs    rw 0 0" >> "${deployment_rootfs_dir}/etc/rdtab"
    echo "rootdev /mnt/mnt  btrfs    rw,noatime,subvol=/,skip_balance,compress=zstd 0 0" >> "${deployment_rootfs_dir}/etc/rdtab"
    echo "overlay /mnt/root overlay  rw,noatime,lowerdir=/mnt/root,upperdir=/mnt/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/root_overlay/upperdir,workdir=/mnt/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/root_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off 0 0" >> "${deployment_rootfs_dir}/etc/rdtab"
    echo "overlay /mnt/etc  overlay  rw,noatime,lowerdir=/mnt/etc,upperdir=/mnt/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/etc_overlay/upperdir,workdir=/mnt/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/etc_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off    0 0" >> "${deployment_rootfs_dir}/etc/rdtab"
    echo "overlay /mnt/var  overlay  rw,noatime,lowerdir=/mnt/var,upperdir=/mnt/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/var_overlay/upperdir,workdir=/mnt/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/var_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off    0 0" >> "${deployment_rootfs_dir}/etc/rdtab"
    readonly RDTAB_MOUNTED=",remount"
else
    readonly RDTAB_MOUNTED=""
fi

# write /etc/fstab with mountpoints
if [ -f "${deployment_rootfs_dir}/usr/lib/systemd/systemd" ]; then
    echo "LABEL=rootfs /home btrfs   rw,noatime,subvol=/${HOME_SUBVOL_NAME},skip_balance,compress=zstd    0  0" >> "${deployment_rootfs_dir}/etc/fstab"
    echo "LABEL=rootfs /mnt btrfs   rw${RDTAB_MOUNTED},noatime,x-initrd.mount,subvol=/,skip_balance,compress=zstd 0  0" >> "${deployment_rootfs_dir}/etc/fstab"
else
    echo "/dev/root /home btrfs   rw,noatime,subvol=/${HOME_SUBVOL_NAME},skip_balance,compress=zstd       0  0" >> "${deployment_rootfs_dir}/etc/fstab"
    echo "/dev/root /mnt btrfs   rw${RDTAB_MOUNTED},noatime,x-initrd.mount,subvol=/,skip_balance,compress=zstd    0  0" >> "${deployment_rootfs_dir}/etc/fstab"
fi

# [1] following two lines makes systemd believe it's running in degraded mode because even if ro is specified the work directory is being created (and thus that fails)
#echo "overlay /usr  overlay ro,noatime,x-initrd.mount,defaults,x-systemd.requires-mounts-for=/mnt,lowerdir=/usr,upperdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/usr_overlay/upperdir,workdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/usr_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,uuid=null                              0  0" >> "${deployment_rootfs_dir}/etc/fstab"
#echo "overlay /opt  overlay ro,noatime,x-initrd.mount,defaults,x-systemd.requires-mounts-for=/mnt,lowerdir=/opt,upperdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/opt_overlay/upperdir,workdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/opt_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,uuid=null                              0  0" >> "${deployment_rootfs_dir}/etc/fstab"
echo "overlay /root overlay rw${RDTAB_MOUNTED},noatime,x-initrd.mount,defaults,x-systemd.requires-mounts-for=/mnt,x-systemd.rw-only,lowerdir=/root,upperdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/root_overlay/upperdir,workdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/root_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,uuid=null 0  0" >> "${deployment_rootfs_dir}/etc/fstab"
echo "overlay /etc  overlay rw${RDTAB_MOUNTED},noatime,x-initrd.mount,defaults,x-systemd.requires-mounts-for=/mnt,x-systemd.rw-only,lowerdir=/etc,upperdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/etc_overlay/upperdir,workdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/etc_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,uuid=null    0  0" >> "${deployment_rootfs_dir}/etc/fstab"
echo "overlay /var  overlay rw${RDTAB_MOUNTED},noatime,x-initrd.mount,defaults,x-systemd.requires-mounts-for=/mnt,x-systemd.rw-only,lowerdir=/var,upperdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/var_overlay/upperdir,workdir=/mnt/${DEPLOYMENTS_DATA_DIR}/${deployment_name}/var_overlay/workdir,index=off,metacopy=off,xino=off,redirect_dir=off,uuid=null    0  0" >> "${deployment_rootfs_dir}/etc/fstab"

################################################################################################
# If atomrootfsinit exists use that as the init system, otherwise use systemd
################################################################################################

if [ -f "${deployment_rootfs_dir}/usr/bin/atomrootfsinit" ]; then
    echo "Using atomrootfsinit as the init system"
    ln -sf /usr/bin/atomrootfsinit "${deployment_rootfs_dir}/usr/bin/init"
else
    if [ -f "${deployment_rootfs_dir}/init" ]; then
        echo "Using the default init system"
    else
        echo "No init system found, exiting"
        exit -1
    fi
fi

if [ -f "${deployment_rootfs_dir}/usr/lib/systemd/systemd" ]; then
    echo "Using preinstalled systemd as the init system"
    echo "/usr/lib/systemd/systemd" > "${deployment_rootfs_dir}/etc/rdexec"
fi

################################################################################################
# Complete the deployment by adding the public key, the settings file and the manifest file
################################################################################################

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

################################################################################################
# Make the deployment bootable by finding the kernel file and linking it to /boot/bzImage
################################################################################################

readonly KERNEL_FILE=$(find "$deployment_rootfs_dir/usr" -name "vmlinu*" | head -n 1)
if [ -f "$KERNEL_FILE" ]; then
    echo "Found kernel file '${KERNEL_FILE}': making it bootable"
    ln "$KERNEL_FILE" "$deployment_rootfs_dir/boot/bzImage"
else
    echo "No kernel file found in ${deployment_rootfs_dir}/usr"
    exit -1
fi
