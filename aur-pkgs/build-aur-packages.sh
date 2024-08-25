#!/bin/bash

set -e
set -x

source manifest;

echo "95.216.144.15 aur.archlinux.org" | sudo tee /etc/hosts

sudo mkdir -p /workdir/aur-pkgs
sudo chown build:build /workdir/aur-pkgs

pikaur --noconfirm -S inputplumber-bin

PIKAUR_CMD="PKGDEST=/workdir/aur-pkgs pikaur --noconfirm -Sw ${AUR_PACKAGES}"
PIKAUR_RUN=(bash -c "${PIKAUR_CMD}")
"${PIKAUR_RUN[@]}"