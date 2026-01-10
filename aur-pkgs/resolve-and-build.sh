#!/usr/bin/env bash
set -euxo pipefail

source manifest
mkdir -p /tmp/aur-src /workdir/aur-pkgs
chown -R build:build /workdir/aur-pkgs

# Clone initial AUR packages listed in manifest
for PKG in ${AUR_PACKAGES}; do
  echo "Cloning ${PKG}"
  sudo -u build git clone --depth=1 https://aur.archlinux.org/${PKG}.git /tmp/aur-src/${PKG} || true
done

collect_deps() {
  local dir="$1"
  (cd "$dir" && makepkg --printsrcinfo 2>/dev/null) || true
}

declare -A deps_map
for d in /tmp/aur-src/*; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  info=$(collect_deps "$d")
  if [ -n "$info" ]; then
    deps=$(echo "$info" | awk -F"= " '/^depends =/ {print $2} /^makedepends =/ {print $2}' | tr "\n" " " )
    deps_map["$name"]="$deps"
  else
    deps_map["$name"]=""
  fi
done

in_repo() { pacman -Si "$1" >/dev/null 2>&1; }

built=()
failed=()
cloned=()

while :; do
  progress=false
  for pkg_dir in /tmp/aur-src/*; do
    [ -d "$pkg_dir" ] || continue
    pkg=$(basename "$pkg_dir")
    if printf "%s\n" "${built[@]}" | grep -qx "$pkg"; then
      continue
    fi
    deps_raw="${deps_map[$pkg]}"
    read -r -a dep_arr <<< "$deps_raw"
    aur_deps=()
    repo_deps=()
    for dep in "${dep_arr[@]}"; do
      [ -z "$dep" ] && continue
      dep_name="${dep%%[><=]*}"
      if in_repo "$dep_name"; then
        repo_deps+=("$dep_name")
      else
        aur_deps+=("$dep_name")
      fi
    done

    can_build=true
    for ad in "${aur_deps[@]}"; do
      if ! printf "%s\n" "${built[@]}" | grep -qx "$ad"; then
        can_build=false
        break
      fi
    done
    if [ "$can_build" = true ]; then
      if [ ${#repo_deps[@]} -ne 0 ]; then
        echo "Installing repo deps for $pkg: ${repo_deps[*]}"
        pacman --noconfirm -S --needed "${repo_deps[@]}" || true
      fi
      echo "Building $pkg"
      if sudo -u build bash -c "cd /tmp/aur-src/$pkg && PKGDEST=/workdir/aur-pkgs makepkg -s --noconfirm -f"; then
        built+=("$pkg")
        progress=true
        echo "Built $pkg"
      else
        echo "Build failed for $pkg, will try to resolve missing deps"
        failed+=("$pkg")
      fi
    else
      for ad in "${aur_deps[@]}"; do
        [ -z "$ad" ] && continue
        if [ ! -d "/tmp/aur-src/$ad" ]; then
          echo "Attempting to clone missing AUR dep: $ad"
          if sudo -u build git clone --depth=1 https://aur.archlinux.org/${ad}.git /tmp/aur-src/${ad}; then
            cloned+=("$ad")
            deps_map["$ad"]="$(collect_deps "/tmp/aur-src/$ad")"
            progress=true
          else
            echo "Could not clone $ad from AUR"
          fi
        fi
      done
    fi
  done
  if [ "$progress" = false ]; then
    echo "No progress made; breaking"
    break
  fi
done

echo "Built packages: ${built[*]}"
remains=()
for d in /tmp/aur-src/*; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  if ! printf "%s\n" "${built[@]}" | grep -qx "$name"; then
    remains+=("$name")
  fi
done

echo "Remaining unbuilt packages: ${remains[*]}"
ls -la /workdir/aur-pkgs || true
