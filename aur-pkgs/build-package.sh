#!/bin/bash

set -x

sudo chown -R build:build /workdir/aur-pkgs

# Build AUR package from local PKGBUILD using makepkg
sudo -u build bash -c "cd /workdir/${1} && PKGDEST=/workdir/aur-pkgs makepkg -s --noconfirm -f"
# remove any epoch (:) in name, replace with -- since not allowed in artifacts
find /workdir/aur-pkgs/*.pkg.tar* -type f -name '*:*' -execdir bash -c 'mv "$1" "${1//:/--}"' bash {} \;