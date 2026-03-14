#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT_NAME=$(basename "$PROJECT_DIR")
DEFAULT_CHROOT_DIR="$PROJECT_DIR/.build/chroot/trixie-amd64"
CHROOT_DIR=${CHROOT_DIR:-$DEFAULT_CHROOT_DIR}
ARCH=${ARCH:-amd64}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
SUITE=${SUITE:-trixie}
SETUP_ONLY=0
ORIGINAL_ARGS=("$@")

usage() {
  cat <<EOF
Usage: tools/build_package.sh [--setup-only] [--chroot-dir PATH]

Builds the Debian package inside a debootstrapped Debian chroot.

Options:
  --setup-only        Create or refresh the chroot, then exit.
  --chroot-dir PATH   Override the default chroot location.
  -h, --help          Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup-only)
      SETUP_ONLY=1
      shift
      ;;
    --chroot-dir)
      [[ $# -ge 2 ]] || { echo "--chroot-dir requires a path" >&2; exit 1; }
      CHROOT_DIR=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  exec sudo --preserve-env=ARCH,MIRROR,SUITE,CHROOT_DIR "$0" "${ORIGINAL_ARGS[@]}"
fi

command -v debootstrap >/dev/null 2>&1 || { echo "debootstrap is required" >&2; exit 1; }
command -v chroot >/dev/null 2>&1 || { echo "chroot is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

CHROOT_SCRIPT=/work/"$PROJECT_NAME"/tools/build_in_chroot.sh
MOUNTS=(
  "$CHROOT_DIR/dev/pts"
  "$CHROOT_DIR/dev"
  "$CHROOT_DIR/proc"
)
HOST_ARTIFACT_DIR="$PROJECT_DIR"
CHROOT_WORK_DIR="$CHROOT_DIR/work"
CHROOT_PROJECT_DIR="$CHROOT_WORK_DIR/$PROJECT_NAME"
CHROOT_SENTINELS=(
  "$CHROOT_DIR/bin/bash"
  "$CHROOT_DIR/usr/bin/dpkg"
  "$CHROOT_DIR/var/lib/dpkg/status"
)

chroot_is_complete() {
  local path
  for path in "${CHROOT_SENTINELS[@]}"; do
    [[ -e "$path" ]] || return 1
  done

  return 0
}

ensure_chroot() {
  if ! chroot_is_complete; then
    rm -rf "$CHROOT_DIR"
    mkdir -p "$CHROOT_DIR"
    debootstrap --arch="$ARCH" --variant=minbase "$SUITE" "$CHROOT_DIR" "$MIRROR"
  fi

  cat > "$CHROOT_DIR/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
EOF

  mkdir -p \
    "$CHROOT_DIR/proc" \
    "$CHROOT_DIR/dev" \
    "$CHROOT_DIR/dev/pts" \
    "$CHROOT_DIR/var/lib/apt/lists/partial" \
    "$CHROOT_DIR/var/cache/apt/archives/partial" \
    "$CHROOT_DIR/var/lib/dpkg" \
    "$CHROOT_DIR/var/log/apt" \
    "$CHROOT_DIR/work"

  touch \
    "$CHROOT_DIR/var/lib/dpkg/status" \
    "$CHROOT_DIR/var/lib/dpkg/available" \
    "$CHROOT_DIR/var/lib/dpkg/lock" \
    "$CHROOT_DIR/var/lib/dpkg/lock-frontend"
}

mount_once() {
  local source=$1
  local target=$2
  shift 2

  if mountpoint -q "$target"; then
    return
  fi

  mount "$@" "$source" "$target"
}

setup_private_dev() {
  mount_once tmpfs "$CHROOT_DIR/dev" -t tmpfs -o mode=755,nosuid
  mkdir -p "$CHROOT_DIR/dev/pts" "$CHROOT_DIR/dev/shm"
  mount_once devpts "$CHROOT_DIR/dev/pts" -t devpts -o gid=5,mode=620,ptmxmode=666,newinstance
  ln -snf pts/ptmx "$CHROOT_DIR/dev/ptmx"
  ln -snf /proc/self/fd "$CHROOT_DIR/dev/fd"
  ln -snf /proc/self/fd/0 "$CHROOT_DIR/dev/stdin"
  ln -snf /proc/self/fd/1 "$CHROOT_DIR/dev/stdout"
  ln -snf /proc/self/fd/2 "$CHROOT_DIR/dev/stderr"
  chmod 1777 "$CHROOT_DIR/dev/shm"

  rm -f \
    "$CHROOT_DIR/dev/null" \
    "$CHROOT_DIR/dev/zero" \
    "$CHROOT_DIR/dev/full" \
    "$CHROOT_DIR/dev/random" \
    "$CHROOT_DIR/dev/urandom" \
    "$CHROOT_DIR/dev/tty"

  mknod -m 666 "$CHROOT_DIR/dev/null" c 1 3
  mknod -m 666 "$CHROOT_DIR/dev/zero" c 1 5
  mknod -m 666 "$CHROOT_DIR/dev/full" c 1 7
  mknod -m 666 "$CHROOT_DIR/dev/random" c 1 8
  mknod -m 666 "$CHROOT_DIR/dev/urandom" c 1 9
  mknod -m 666 "$CHROOT_DIR/dev/tty" c 5 0
}

stage_project_into_chroot() {
  rm -rf "$CHROOT_PROJECT_DIR"
  mkdir -p "$CHROOT_WORK_DIR"

  tar \
    --exclude=.git \
    --exclude=.build \
    --exclude=drive_test_reports \
    --exclude=preflight_reports \
    -C "$(dirname "$PROJECT_DIR")" \
    -cf - \
    "$PROJECT_NAME" | tar -C "$CHROOT_WORK_DIR" -xf -
}

collect_artifacts() {
  shopt -s nullglob
  local artifact
  local patterns=(
    "$CHROOT_WORK_DIR"/raid-drive-validator_*.deb
    "$CHROOT_WORK_DIR"/raid-drive-validator_*.buildinfo
    "$CHROOT_WORK_DIR"/raid-drive-validator_*.changes
    "$CHROOT_WORK_DIR"/raid-drive-validator_*.build
  )

  for artifact in "${patterns[@]}"; do
    cp -f "$artifact" "$HOST_ARTIFACT_DIR/"
  done
  shopt -u nullglob
}

cleanup() {
  local status=$?
  local target

  if mountpoint -q "$CHROOT_DIR/dev"; then
    umount -R "$CHROOT_DIR/dev" || umount -l "$CHROOT_DIR/dev" || true
  fi

  for (( idx=${#MOUNTS[@]}-1; idx>=0; idx-- )); do
    target=${MOUNTS[$idx]}
    [[ $target == "$CHROOT_DIR/dev" ]] && continue
    if mountpoint -q "$target"; then
      umount "$target" || umount -l "$target" || true
    fi
  done

  return "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ensure_chroot

if (( SETUP_ONLY )); then
  echo "Trixie chroot ready at $CHROOT_DIR"
  exit 0
fi

mount_once proc "$CHROOT_DIR/proc" -t proc
setup_private_dev
stage_project_into_chroot

chroot "$CHROOT_DIR" /bin/bash -lc "cd /work/$PROJECT_NAME && $CHROOT_SCRIPT"
collect_artifacts

echo "Build complete. Artifacts are in $PROJECT_DIR"
