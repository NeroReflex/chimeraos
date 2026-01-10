#!/usr/bin/env bash
# Local CI runner for chimeraos AUR builds
# Usage:
#   ./script/local-ci.sh build-image        # build the chimeraos-ci Docker image
#   ./script/local-ci.sh package <name>     # build a single AUR package inside the CI image
#   ./script/local-ci.sh all                # run the full resolver inside the CI image

set -euo pipefail
set -x

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="chimeraos-ci"

usage() {
  cat <<EOF
Usage: $0 <command>
Commands:
  build-image         Build the CI Docker image (from Dockerfile)
  package <name>      Build a single AUR package (non-interactive)
  all                 Run the full AUR resolver to build all AUR packages
  help                Show this message
EOF
}

cmd=${1-}
case "$cmd" in
  build-image)
    docker build -t "$IMAGE_NAME" "$ROOT_DIR"
    ;;

  package)
    pkg=${2-}
    if [ -z "$pkg" ]; then
      echo "package name required" >&2
      usage
      exit 2
    fi
    docker run --rm -v "$ROOT_DIR":/workdir -w /workdir "$IMAGE_NAME" \
      bash -eux /workdir/aur-pkgs/build-aur-package.sh "$pkg"
    ;;

  all)
    docker run --rm -v "$ROOT_DIR":/workdir -w /workdir "$IMAGE_NAME" \
      bash -eux /workdir/aur-pkgs/resolve-and-build.sh
    ;;

  help|""|*)
    usage
    exit 1
    ;;
esac
