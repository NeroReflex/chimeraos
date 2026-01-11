#!/bin/bash

set -x

sudo chown -R build:build /workdir/pkgs

# Build package from local PKGBUILD
sudo -u build bash -c "cd /workdir/${1} && PKGDEST=/workdir/pkgs paru -Bi --needed --noconfirm ."
# remove any epoch (:) in name, replace with -- since not allowed in artifacts
find /workdir/pkgs/*.pkg.tar* -type f -name '*:*' -execdir bash -c 'mv "$1" "${1//:/--}"' bash {} \;