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

in_repo() { pacman -Si "$1" >/dev/null 2>&1; }

collect_deps() {
  local dir="$1"
  local info
  info=$(cd "$dir" && makepkg --printsrcinfo 2>/dev/null) || info=""
  printf "%s\n" "$info" \
    | sed -nE "s/^[[:space:]]*(depends(_[[:alnum:]]+)?|makedepends)[[:space:]]*=[[:space:]]*(.*)$/\3/p" \
    | tr ' ' '\\n' \
    | sed 's/[\",]//g' \
    | sed '/^[[:space:]]*$/d'
}

# Resolve the canonical AUR package name for a dependency using the AUR RPC API.
# Returns the package 'Name' if found, otherwise empty string.
aur_resolve_name() {
  local name="$1"
  local json
  json=$(curl -fsS "https://aur.archlinux.org/rpc/?v=5&type=info&arg=${name}" 2>/dev/null || true)
  if [ -n "$json" ]; then
  # Use python for robust JSON parsing
  printf "%s" "$json" | python3 - <<'PY'
import sys, json
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(0)
r=j.get('results')
if not r:
  sys.exit(0)
if isinstance(r, dict):
  print(r.get('Name',''))
elif isinstance(r, list) and len(r)>0:
  print(r[0].get('Name',''))
PY
  return
  fi

  # fallback: try a search query
  json=$(curl -fsS "https://aur.archlinux.org/rpc/?v=5&type=search&arg=${name}" 2>/dev/null || true)
  if [ -n "$json" ]; then
  printf "%s" "$json" | python3 - <<'PY'
import sys, json
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(0)
arr=j.get('results')
if isinstance(arr, list) and len(arr)>0:
  print(arr[0].get('Name',''))
PY
  fi
}

build_aur_pkg() {
  local pkg="$1"
  local srcdir="/tmp/aur-src/$pkg"

  if already_built "$pkg"; then
    echo "$pkg already built; skipping"
    return 0
  fi

    if [ ! -d "$srcdir" ]; then
      # Resolve canonical AUR repo name (some packages use different pkgbase/name)
      resolved=$(aur_resolve_name "$pkg" || true)
      if [ -n "$resolved" ]; then
        repo_name="$resolved"
      else
        repo_name="$pkg"
      fi

    # If the cloned repo doesn't contain a PKGBUILD (empty AUR repo), try paru as a last-resort
    if [ ! -f "$srcdir/PKGBUILD" ]; then
      echo "Cloned AUR repo for $pkg has no PKGBUILD. Trying to satisfy via paru..."
      if command -v paru >/dev/null 2>&1; then
        # try to install the package (repo or AUR) non-interactively
        if sudo paru -S --noconfirm --needed "$pkg"; then
          echo "Installed $pkg via paru; treating as satisfied"
          return 0
        else
          echo "paru failed to install $pkg; will attempt normal build and may fail" >&2
        fi
      else
        echo "paru not available; cannot fallback for $pkg" >&2
      fi
    fi

      # Try cloning using resolved name, fallback to tried variants
      if ! sudo -u build git clone --depth=1 https://aur.archlinux.org/${repo_name}.git "$srcdir"; then
        # try adding -git suffix
        if ! sudo -u build git clone --depth=1 https://aur.archlinux.org/${pkg}-git.git "$srcdir"; then
          if ! sudo -u build git clone --depth=1 https://aur.archlinux.org/${pkg}.git "$srcdir"; then
            echo "Failed to clone AUR package: $pkg (tried ${repo_name}, ${pkg}-git, ${pkg})" >&2
            return 1
          fi
        fi
      fi
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
        # Heuristics for sonames / virtual libs: skip or map to known repo packages
        if [[ "$dep_name" == *.* ]]; then
          # tokens like libfmt.so, libzip.so — try to map or skip
          echo "Dependency $dep_name looks like a soname or file; attempting to map or skip"
          case "$dep_name" in
            libgl)
              mapped_pkg=mesa
              ;;
            libGL.so*|libGL*)
              mapped_pkg=mesa
              ;;
            libfmt.so*)
              mapped_pkg=fmt9
              ;;
            libzip.so*)
              mapped_pkg=libzip
              ;;
            libzstd.so*)
              mapped_pkg=zstd
              ;;
            libryml.so*)
              mapped_pkg=rapidyaml
              ;;
            *)
              mapped_pkg=""
              ;;
          esac
          if [ -n "$mapped_pkg" ]; then
            echo "Mapping $dep_name -> $mapped_pkg and installing"
            sudo pacman -S --noconfirm --needed "$mapped_pkg" || true
            continue
          else
            echo "No mapping for $dep_name; assuming provided by base system or skipped"
            continue
          fi
        fi

        echo "Dependency $dep_name not in repo; building from AUR"
        if [ "$dep_name" = "$pkg" ]; then
          echo "Skipping self-dependency for $pkg"
          continue
        fi
        if ! build_aur_pkg "$dep_name"; then
          echo "Failed to build AUR dependency: $dep_name" >&2
          if command -v paru >/dev/null 2>&1; then
            echo "Attempting to install $dep_name via paru as a last-resort"
            if sudo paru -S --noconfirm --needed "$dep_name"; then
              echo "Installed $dep_name via paru; continuing"
              continue
            else
              echo "paru failed to install $dep_name" >&2
            fi
          fi
          return 1
        fi
        # Try to install the locally-built package if present
        pkg_files=(/workdir/aur-pkgs/*"$dep_name"*.pkg.tar*)
        if [ ${#pkg_files[@]} -gt 0 ] && [ -e "${pkg_files[0]}" ]; then
          sudo pacman -U --noconfirm --needed "${pkg_files[@]}" || true
        fi
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
