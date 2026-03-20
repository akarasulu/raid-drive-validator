#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/by-id" "$tmpdir/devices"
: > "$tmpdir/devices/sdb"
: > "$tmpdir/devices/sdc"
: > "$tmpdir/devices/sdd"
: > "$tmpdir/devices/sde"
: > "$tmpdir/devices/sdf"

ln -s "$tmpdir/devices/sdb" "$tmpdir/by-id/ata-ST4000DM000_Z1"
ln -s "$tmpdir/devices/sdb" "$tmpdir/by-id/wwn-0x5000c500aabbcc01"
ln -s "$tmpdir/devices/sdc" "$tmpdir/by-id/ata-HGST_HDN724040ALE640_Z2"
ln -s "$tmpdir/devices/sdc" "$tmpdir/by-id/scsi-35000cca22ddeeff0"
ln -s "$tmpdir/devices/sdd" "$tmpdir/by-id/ata-ST4000DM000_Z3"
ln -s "$tmpdir/devices/sde" "$tmpdir/by-id/wwn-0x5000c500aabbcc04"
ln -s "$tmpdir/devices/sdf" "$tmpdir/by-id/ata-ST4000DM000_Z5"

cat > "$tmpdir/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
NAME="sdb" SIZE="3.6T" MODEL="ST4000DM000-1F2168" VENDOR="ATA" TYPE="disk"
NAME="sdc" SIZE="3.6T" MODEL="HGST HDN724040ALE640" VENDOR="ATA" TYPE="disk"
NAME="sdd" SIZE="3.6T" MODEL="ST4000DM000-1F2168" VENDOR="ATA" TYPE="disk"
NAME="sde" SIZE="3.6T" MODEL="HGST HDN724040ALE640" VENDOR="ATA" TYPE="disk"
NAME="sdf" SIZE="3.6T" MODEL="ST4000DM000-1F2168" VENDOR="ATA" TYPE="disk"
NAME="sdg" SIZE="931.5G" MODEL="Samsung SSD 840 EVO 1TB" VENDOR="ATA" TYPE="disk"
OUT
EOF

cat > "$tmpdir/bin/readlink" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -f && ${2:-} == -- ]]; then
  case "${3:-}" in
    /dev/sdb) printf '%s/devices/sdb\n' "$TEST_ROOT"; exit 0 ;;
    /dev/sdc) printf '%s/devices/sdc\n' "$TEST_ROOT"; exit 0 ;;
    /dev/sdd) printf '%s/devices/sdd\n' "$TEST_ROOT"; exit 0 ;;
    /dev/sde) printf '%s/devices/sde\n' "$TEST_ROOT"; exit 0 ;;
    /dev/sdf) printf '%s/devices/sdf\n' "$TEST_ROOT"; exit 0 ;;
  esac
fi
exec /usr/bin/readlink "$@"
EOF

chmod +x "$tmpdir/bin/lsblk" "$tmpdir/bin/readlink"

output=$(
  PATH="$tmpdir/bin:$PATH" \
  TEST_ROOT="$tmpdir" \
  DISK_BY_ID_DIR="$tmpdir/by-id" \
  bash tools/create_raidz2_pool.sh \
    --pool-name backup \
    --model ST4000 \
    --model HGST \
    --size 3.6T \
    --drive-count 4 \
    --spare-count 1
)

expected="zpool create -o ashift=12 backup raidz2 $tmpdir/by-id/ata-ST4000DM000_Z1 $tmpdir/by-id/ata-HGST_HDN724040ALE640_Z2 $tmpdir/by-id/ata-ST4000DM000_Z3 $tmpdir/by-id/wwn-0x5000c500aabbcc04 spare $tmpdir/by-id/ata-ST4000DM000_Z5"

[[ "$output" == "$expected" ]]

wwn_output=$(
  PATH="$tmpdir/bin:$PATH" \
  TEST_ROOT="$tmpdir" \
  DISK_BY_ID_DIR="$tmpdir/by-id" \
  bash tools/create_raidz2_pool.sh \
    --pool-name backup \
    --model ST4000 \
    --model HGST \
    --size 3.6T \
    --drive-count 4 \
    --spare-count 1 \
    --wwn
)

wwn_expected="zpool create -o ashift=12 backup raidz2 $tmpdir/by-id/wwn-0x5000c500aabbcc01 $tmpdir/by-id/ata-HGST_HDN724040ALE640_Z2 $tmpdir/by-id/ata-ST4000DM000_Z3 $tmpdir/by-id/wwn-0x5000c500aabbcc04 spare $tmpdir/by-id/ata-ST4000DM000_Z5"

[[ "$wwn_output" == "$wwn_expected" ]]

if PATH="$tmpdir/bin:$PATH" TEST_ROOT="$tmpdir" DISK_BY_ID_DIR="$tmpdir/by-id" \
  bash tools/create_raidz2_pool.sh --pool-name backup --model ST4000 --model HGST --size 3.6T --drive-count 4 --spare-count 2 >/dev/null 2>&1; then
  echo "expected drive-count mismatch to fail"
  exit 1
fi

echo "zpool create helper tests passed"
