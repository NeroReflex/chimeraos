#!/bin/bash

set -x

sudo chown -R build:build /workdir/aur-pkgs

# Build AUR package from local PKGBUILD using paru
sudo -u build bash -c "paru -B --needed --noconfirm /workdir/${1}"
# remove any epoch (:) in name, replace with -- since not allowed in artifacts
find /workdir/aur-pkgs/*.pkg.tar* -type f -name '*:*' -execdir bash -c 'mv "$1" "${1//:/--}"' bash {} \;