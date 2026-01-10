#!/bin/bash

set -x

sudo chown -R build:build /workdir/pkgs

# ChimeraOS now uses dracut and excludes mkinitcpio due to pacman hooks causing problems
# Ensure package conflicting with mkinitcpio can be built
sudo pacman -S --noconfirm dracut
sudo pacman -R --noconfirm mkinitcpio

# Build package from local PKGBUILD without pikaur: use makepkg as build user
sudo -u build bash -c "cd /workdir/${1} && PKGDEST=/workdir/pkgs makepkg -sfi --noconfirm -f"
# remove any epoch (:) in name, replace with -- since not allowed in artifacts
find /workdir/pkgs/*.pkg.tar* -type f -name '*:*' -execdir bash -c 'mv "$1" "${1//:/--}"' bash {} \;