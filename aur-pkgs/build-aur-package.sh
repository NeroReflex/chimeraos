#!/bin/bash

set -euo pipefail
#!/usr/bin/env bash

set -euo pipefail
set -x

if [ -z "${1-}" ]; then
  echo "Usage: $0 <aur-package-name>" >&2
  exit 2
fi

PKGNAME="$1"
source manifest || true

mkdir -p /tmp/aur-src /workdir/aur-pkgs
if [ "$(id -u)" -eq 0 ]; then
  chown -R build:build /tmp/aur-src 2>/dev/null || echo "Warning: chown /tmp/aur-src failed; continuing" >&2
  chown -R build:build /workdir/aur-pkgs 2>/dev/null || echo "Warning: chown /workdir/aur-pkgs failed; continuing" >&2
else
  echo "Not running as root; skipping chown operations"
fi

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
  (cd "$dir" && makepkg --printsrcinfo 2>/dev/null) | python3 "$(dirname "$0")/parse_deps.py"
}

aur_resolve_name() {
  local name="$1"
  python3 "$(dirname "$0")/aur_resolve.py" "$name" || true
}

parse_pkgbuild_deps() {
  local dir="$1"
  local pkgb="$dir/PKGBUILD"
  [ -f "$pkgb" ] || return 0
  python3 - "$pkgb" <<'PY'
import re,sys
p=sys.argv[1]
try:
    s=open(p,'r',encoding='utf-8',errors='ignore').read()
except Exception:
    sys.exit(0)
out=[]
for key in ('depends','makedepends'):
    for m in re.finditer(r'(?ms)'+key+r'\s*=\s*\((.*?)\)', s):
        inner=m.group(1)
        parts=re.findall(r'["\']?([^"\',\s]+)["\']?', inner)
        out.extend(parts)
print('\n'.join(out))
PY
}

install_aur_via_makepkg() {
  local target="$1"
  local src="/tmp/aur-src/$target"
  if [ -d "$src" ]; then
    sudo -u build git -C "$src" pull --rebase || true
  else
    if ! sudo -u build git clone --depth=1 "https://aur.archlinux.org/${target}.git" "$src"; then
      return 1
    fi
  fi
  if [ -f "$src/PKGBUILD" ]; then
    if sudo -u build bash -c "cd $src && PKGDEST=/workdir/aur-pkgs makepkg -s --noconfirm -f"; then
      return 0
    fi
  fi
  return 1
}

install_aur_or_paru() {
  local name="$1"
  local resolved
  resolved=$(aur_resolve_name "$name" || true)
  local target=${resolved:-$name}
  if is_installed "$target"; then
    echo "Package $target already installed in DB; skipping paru fallback"
    return 0
  fi
  if install_aur_via_makepkg "$target"; then
    # install built package(s) if any
    pkg_files=(/workdir/aur-pkgs/*"$target"*.pkg.tar*)
    if [ ${#pkg_files[@]} -gt 0 ] && [ -e "${pkg_files[0]}" ]; then
      sudo -u build paru -U --noconfirm --needed "${pkg_files[@]}" || true
    fi
    return 0
  fi

  # fallback to paru (non-root). Use resolved canonical name when available.
  sudo -u build paru -S --noconfirm --needed "$target" || return 1
}

build_aur_pkg() {
  local pkg="$1"
  local srcdir="/tmp/aur-src/$pkg"

  if already_built "$pkg"; then
    echo "$pkg already built; skipping"
    return 0
  fi

  if [ ! -d "$srcdir" ]; then
    local resolved
    resolved=$(aur_resolve_name "$pkg" || true)
    if [ -n "$resolved" ]; then
      repo_name="$resolved"
    else
      repo_name="$pkg"
    fi

    if ! sudo -u build git clone --depth=1 "https://aur.archlinux.org/${repo_name}.git" "$srcdir"; then
      if ! sudo -u build git clone --depth=1 "https://aur.archlinux.org/${pkg}-git.git" "$srcdir"; then
        if ! sudo -u build git clone --depth=1 "https://aur.archlinux.org/${pkg}.git" "$srcdir"; then
          echo "Failed to clone AUR package: $pkg (tried ${repo_name}, ${pkg}-git, ${pkg})" >&2
          if command -v paru >/dev/null 2>&1; then
            if install_aur_or_paru "$pkg"; then
              echo "Installed $pkg via fallback; treating as satisfied"
              return 0
            else
              echo "paru/install fallback failed for $pkg" >&2
            fi
          fi
          return 1
        fi
      fi
    fi
  else
    sudo -u build git -C "$srcdir" pull --rebase || true
  fi

  if [ ! -f "$srcdir/PKGBUILD" ]; then
    echo "Cloned AUR repo for $pkg has no PKGBUILD. Trying paru fallback..."
    if command -v paru >/dev/null 2>&1; then
      if install_aur_or_paru "$pkg"; then
        echo "Installed $pkg via fallback; treating as satisfied"
        return 0
      else
        echo "paru/install fallback failed for $pkg; will attempt normal build and may fail" >&2
      fi
    else
      echo "paru not available; cannot fallback for $pkg" >&2
    fi
  fi

  deps_raw=$(collect_deps "$srcdir") || deps_raw=""
  if [ -z "${deps_raw:-}" ]; then
    deps_raw=$(parse_pkgbuild_deps "$srcdir" 2>/dev/null || true)
  fi
  printf "%s\n" "$deps_raw" > /tmp/dependencies.txt || true

  echo "Installing dependencies for $pkg:"
  mapfile -t dep_arr < <(printf "%s\n" "$deps_raw" | sed '/^[[:space:]]*$/d') || true

  for dep in "${dep_arr[@]}"; do
    dep="${dep//\"/}"
    dep="${dep//,/}"
    if [ -z "$dep" ]; then
      continue
    fi

    dep_name="${dep%%[><=]*}"
    dep_name="${dep_name%%:*}"
    dep_name="${dep_name%%/*}"

    [ -z "$dep_name" ] && continue

    if already_built "$dep_name"; then
      echo "Dependency $dep_name already built; skipping"
      continue
    fi

    if in_repo "$dep_name"; then
      echo "Installing repo dependency: $dep_name"
      paru_target="$dep_name"
      resolved_paru=$(aur_resolve_name "$dep_name" || true)
      if [ -n "$resolved_paru" ]; then
        paru_target="$resolved_paru"
      fi
      sudo -u build paru -S --noconfirm --needed "$paru_target" || true
    else
      if [[ "$dep_name" == *.* ]]; then
        echo "Dependency $dep_name looks like a soname or file; attempting to map or skip"
        case "$dep_name" in
          libgl|libGL* ) mapped_pkg=mesa ;;
          libfmt.so* ) mapped_pkg=fmt9 ;;
          libzip.so* ) mapped_pkg=libzip ;;
          libzstd.so* ) mapped_pkg=zstd ;;
          libryml.so* ) mapped_pkg=rapidyaml ;;
          *) mapped_pkg="" ;;
        esac
        if [ -n "$mapped_pkg" ]; then
          echo "Mapping $dep_name -> $mapped_pkg and installing"
          sudo -u build paru -S --noconfirm --needed "$mapped_pkg" || true
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
          paru_target="$dep_name"
          resolved_paru=$(aur_resolve_name "$dep_name" || true)
          if [ -n "$resolved_paru" ]; then
            paru_target="$resolved_paru"
          fi
          if install_aur_or_paru "$paru_target"; then
            echo "Installed $paru_target via fallback; continuing"
            continue
          else
            echo "paru/install failed to install $paru_target" >&2
          fi
        fi
        return 1
      fi

      pkg_files=(/workdir/aur-pkgs/*"$dep_name"*.pkg.tar*)
      if [ ${#pkg_files[@]} -gt 0 ] && [ -e "${pkg_files[0]}" ]; then
        sudo -u build paru -U --noconfirm --needed "${pkg_files[@]}" || true
      fi
    fi
  done

  if sudo chown -R build:build "/workdir/aur-pkgs" 2>/dev/null; then
    echo "Changed ownership of /workdir/aur-pkgs to build user"
  else
    echo "Warning: unable to chown /workdir/aur-pkgs; continuing" >&2
  fi

  # Install any already-built local artifacts so pacman/makepkg can
  # resolve dependencies against them without hitting remote repos.
  shopt -s nullglob
  prebuilt=(/workdir/aur-pkgs/*.pkg.tar*)
  if [ ${#prebuilt[@]} -gt 0 ] && [ -e "${prebuilt[0]}" ]; then
    echo "Installing existing local packages into DB: ${#prebuilt[@]} files"
    sudo -u build paru -U --noconfirm --needed "${prebuilt[@]}" || true
  fi

  echo "Building $pkg"
  if sudo -u build bash -c "cd $srcdir && PKGDEST=/workdir/aur-pkgs makepkg -s --noconfirm -f"; then
    # Install any locally-built package files so downstream makepkg/pacman
    # can find them as dependencies without prompting.
    pkg_files=(/workdir/aur-pkgs/*"$pkg"*.pkg.tar*)
    if [ ${#pkg_files[@]} -gt 0 ] && [ -e "${pkg_files[0]}" ]; then
      sudo -u build paru -U --noconfirm --needed "${pkg_files[@]}" || true
    fi

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
      echo "Dependency $dep_name not in repo; building from AUR"
