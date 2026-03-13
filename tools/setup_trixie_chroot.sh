#!/usr/bin/env bash
set -Eeuo pipefail

CHROOT_DIR=${1:-/srv/chroot/trixie-amd64}
ARCH=${ARCH:-amd64}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
SUITE=${SUITE:-trixie}

[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
command -v debootstrap >/dev/null 2>&1 || { echo 'debootstrap is required'; exit 1; }

mkdir -p "$CHROOT_DIR"
debootstrap --arch="$ARCH" --variant=minbase "$SUITE" "$CHROOT_DIR" "$MIRROR"

cat > "$CHROOT_DIR/etc/apt/sources.list" <<SRC
deb $MIRROR $SUITE main contrib non-free-firmware
SRC

mountpoint -q "$CHROOT_DIR/proc" || mount -t proc proc "$CHROOT_DIR/proc"
mountpoint -q "$CHROOT_DIR/sys" || mount --rbind /sys "$CHROOT_DIR/sys"
mountpoint -q "$CHROOT_DIR/dev" || mount --rbind /dev "$CHROOT_DIR/dev"

chroot "$CHROOT_DIR" /bin/bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential debhelper devscripts dpkg-dev fakeroot lintian make shellcheck file python3 smartmontools fio tmux e2fsprogs util-linux'

echo "Trixie chroot ready at $CHROOT_DIR"
