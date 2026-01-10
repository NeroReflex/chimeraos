#!/bin/bash

set -euo pipefail
set -x

if [ -z "${1-}" ]; then
  echo "Usage: $0 <aur-package-name>" >&2
  exit 2
fi

PKGNAME="$1"
source manifest || true

mkdir -p /tmp/aur-src /workdir/aur-pkgs
chown -R build:build /tmp/aur-src || true
chown -R build:build /workdir/aur-pkgs || true

already_built() {
  local name="$1"
  shopt -s nullglob
  for f in /workdir/aur-pkgs/*"$name"*.pkg.tar*; do
    [ -f "$f" ] && return 0
  done
  return 1
}

in_repo() { paru -Si "$1" >/dev/null 2>&1; }

collect_deps() {
  local dir="$1"
  local info
  info=$(cd "$dir" && makepkg --printsrcinfo 2>/dev/null) || info=""
  echo "$info" | awk -F"= " '/^depends =/ {print $2} /^makedepends =/ {print $2}' | tr '\n' ' ' | tr -d '()",'
}

build_aur_pkg() {
  local pkg="$1"
  local srcdir="/tmp/aur-src/$pkg"

  if already_built "$pkg"; then
    echo "$pkg already built; skipping"
    return 0
  fi

  if [ ! -d "$srcdir" ]; then
    sudo -u build git clone --depth=1 https://aur.archlinux.org/${pkg}.git "$srcdir" || {
      echo "Failed to clone AUR package: $pkg" >&2
      return 1
    }
  else
    sudo -u build git -C "$srcdir" pull --rebase || true
  fi

    deps_raw=$(collect_deps "$srcdir")
    # Save for debugging/inspection
    printf "%s\n" "$deps_raw" > /tmp/dependencies.txt || true

    echo "Installing dependencies for $pkg:"
    # Read dependencies into an array, one per line
    mapfile -t dep_arr < <(printf "%s\n" "$deps_raw" | sed '/^[[:space:]]*$/d') || true

    for dep in "${dep_arr[@]}"; do
      dep="${dep//\"/}"
      dep="${dep//\'/}"
      dep="${dep//,/}"
      if [ -z "$dep" ]; then
        # if the raw token is empty after cleanup, skip
        [ -z "$dep" ] && continue
      fi
      # Strip any version constraints, keep package name only
      dep_name="${dep%%[><=]*}"
      dep_name="${dep_name%%:*}" # strip namespace if present
      dep_name="${dep_name%%/*}"

      [ -z "$dep_name" ] && continue

      if already_built "$dep_name"; then
        echo "Dependency $dep_name already built; skipping"
        continue
      fi

      if in_repo "$dep_name"; then
        echo "Installing repo dependency: $dep_name"
        sudo pacman -S --noconfirm --needed "$dep_name" || true
      else
        echo "Dependency $dep_name not in repo; building from AUR"
        if [ "$dep_name" = "$pkg" ]; then
          echo "Skipping self-dependency for $pkg"
          continue
        fi
        if ! build_aur_pkg "$dep_name"; then
          echo "Failed to build AUR dependency: $dep_name" >&2
          return 1
        fi
        # Try to install the locally-built package if present
        sudo pacman -U --noconfirm --needed /workdir/aur-pkgs/*"$dep_name"*.pkg.tar* || true
      fi
    done

  if sudo chown -R build:build "/workdir/aur-pkgs"; then
    echo "Changed ownership of /workdir/aur-pkgs to build user"
  else
    echo "Failed to change ownership of /workdir/aur-pkgs" >&2
    return 1
  fi

  echo "Building $pkg"
  if sudo -u build bash -c "cd '$srcdir' && PKGDEST=/workdir/aur-pkgs makepkg -s --noconfirm -f"; then
    echo "Built $pkg successfully"
    return 0
  else
    echo "Build failed for $pkg" >&2
    return 1
  fi
}

if build_aur_pkg "$PKGNAME"; then
  for f in /workdir/aur-pkgs/*.pkg.tar*; do
    [ -e "$f" ] || continue
    if [[ "$(basename "$f")" == *:* ]]; then
      mv "$f" "${f//:/--}"
    fi
  done
  exit 0
else
  echo "Failed to build $PKGNAME after dependency resolution" >&2
  exit 1
fi
