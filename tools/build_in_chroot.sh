#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  debhelper \
  devscripts \
  dpkg-dev \
  fakeroot \
  make

dpkg-buildpackage -us -uc -b
