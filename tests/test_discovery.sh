#!/usr/bin/env bash
set -euo pipefail
source ./lib/disk_discovery.sh

lsblk() {
  cat <<'EOF'
NAME="sdb" SIZE="3.6T" MODEL="ST4000DM000-1F2168" VENDOR="ATA" TYPE="disk"
NAME="sdc" SIZE="3.6T" MODEL="HGST HDN724040ALE640" VENDOR="ATA" TYPE="disk"
NAME="sdd" SIZE="931.5G" MODEL="Samsung SSD 840 EVO 1TB" VENDOR="ATA" TYPE="disk"
EOF
}

mapfile -t mixed < <(discover_matching_drives $'ST4000\nHGST' '3.6T')
[[ ${#mixed[@]} -eq 2 ]]
[[ ${mixed[0]} == /dev/sdb ]]
[[ ${mixed[1]} == /dev/sdc ]]

mapfile -t size_filtered < <(discover_matching_drives '' $'3.6T\n931.5G')
[[ ${#size_filtered[@]} -eq 3 ]]
[[ ${size_filtered[0]} == /dev/sdb ]]
[[ ${size_filtered[1]} == /dev/sdc ]]
[[ ${size_filtered[2]} == /dev/sdd ]]

echo "discovery helper tests passed"
