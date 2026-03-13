#!/usr/bin/env bash
set -Eeuo pipefail

CHROOT_DIR=${1:-/srv/chroot/trixie-amd64}
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT_NAME=$(basename "$PROJECT_DIR")

[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
[[ -d "$CHROOT_DIR" ]] || { echo "Missing chroot: $CHROOT_DIR"; exit 1; }

mkdir -p "$CHROOT_DIR/work"
mountpoint -q "$CHROOT_DIR/work/$PROJECT_NAME" || mount --bind "$PROJECT_DIR" "$CHROOT_DIR/work/$PROJECT_NAME"
mountpoint -q "$CHROOT_DIR/proc" || mount -t proc proc "$CHROOT_DIR/proc"
mountpoint -q "$CHROOT_DIR/sys" || mount --rbind /sys "$CHROOT_DIR/sys"
mountpoint -q "$CHROOT_DIR/dev" || mount --rbind /dev "$CHROOT_DIR/dev"

chroot "$CHROOT_DIR" /bin/bash -lc "cd /work/$PROJECT_NAME && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential debhelper devscripts dpkg-dev fakeroot lintian make shellcheck file python3 smartmontools fio tmux e2fsprogs util-linux && dpkg-buildpackage -us -uc -b"

echo "Build complete. Look in $(dirname "$PROJECT_DIR") for .deb artifacts."
