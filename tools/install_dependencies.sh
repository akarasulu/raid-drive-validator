#!/usr/bin/env bash
set -Eeuo pipefail
sudo apt-get update
sudo apt-get install -y \
  smartmontools \
  fio \
  tmux \
  e2fsprogs \
  util-linux \
  coreutils \
  gawk \
  grep \
  sed \
  python3 \
  shellcheck
