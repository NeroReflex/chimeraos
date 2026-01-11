#!/bin/bash

set -e
set -x

source manifest;

sudo mkdir -p /workdir/aur-pkgs
sudo chown build:build /workdir/aur-pkgs

# For each AUR package, clone the repo and download sources (non-interactive)
for PKG in ${AUR_PACKAGES}; do
	echo "Processing AUR package: ${PKG}"
	sudo -u build git clone --depth=1 https://aur.archlinux.org/${PKG}.git /tmp/${PKG} || { echo "clone failed for ${PKG}"; continue; }
	sudo -u build bash -c "paru -B --needed --noconfirm /tmp/${PKG}"
done