#!/bin/bash
# Build patched Ubuntu noble packages (run inside the build VM, as a user with sudo).
# Usage: build-packages.sh <patches-dir> [package...]   (default: all three)
set -euo pipefail
PATCHES=$(realpath "${1:?patches dir}"); shift
PKGS=("${@:-mutter gdm3 gnome-remote-desktop}")
[ $# -eq 0 ] && PKGS=(mutter gdm3 gnome-remote-desktop)
mkdir -p ~/build && cd ~/build
for pkg in "${PKGS[@]}"; do
  echo "=== $pkg"
  rm -rf "$pkg"-src && mkdir "$pkg"-src && cd "$pkg"-src
  apt-get source -q "$pkg" >/dev/null 2>&1
  cd "$(find . -maxdepth 1 -mindepth 1 -type d | head -1)"
  patch -p1 < "$PATCHES/$pkg-rdp-session-handoff.patch"
  DEBEMAIL="rdp-handoff@localhost" DEBFULLNAME="rdp-handoff" \
    dch -l +rdphandoff "Local <-> remote (RDP) console session handoff." >/dev/null 2>&1
  DEB_BUILD_OPTIONS="nocheck nodoc parallel=$(nproc)" \
    dpkg-buildpackage -b -uc -us > ../build.log 2>&1 || { tail -40 ../build.log; exit 1; }
  cd ~/build
  ls "$pkg"-src/*.deb
done
