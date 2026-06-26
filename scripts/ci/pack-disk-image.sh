#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") BOOT_IMAGE ROOTFS_IMAGE OUTPUT_IMAGE

Compose a GPT disk image from an existing FAT boot image and ext4 rootfs image.

This is device-structure logic, not distro-specific. Works identically for
Arch Linux ARM and Ubuntu.

Environment inputs:
  BOOT_PARTLABEL            default: ESP
  ROOTFS_PARTLABEL          default: userdata
  ROOTFS_UUID               optional ext4 UUID to set before embedding
USAGE
}

[ $# -eq 3 ] || { usage >&2; exit 2; }

BOOT_IMAGE=$1
ROOTFS_IMAGE=$2
OUTPUT_IMAGE=$3
BOOT_PARTLABEL=${BOOT_PARTLABEL:-ESP}
ROOTFS_PARTLABEL=${ROOTFS_PARTLABEL:-userdata}

ci_require_cmd sgdisk
ci_require_cmd truncate
ci_require_cmd dd
ci_require_cmd stat
ci_require_cmd e2fsck
ci_require_cmd tune2fs

[ -f "$BOOT_IMAGE" ] || ci_die "missing boot image: $BOOT_IMAGE"
[ -f "$ROOTFS_IMAGE" ] || ci_die "missing root image: $ROOTFS_IMAGE"

ceil_div() { echo $(( ($1 + $2 - 1) / $2 )); }
align_up() { echo $(( (($1 + $2 - 1) / $2) * $2 )); }

sector_size=512
first_sector=2048
align_sectors=2048
boot_size=$(stat -c%s "$BOOT_IMAGE")
root_size=$(stat -c%s "$ROOTFS_IMAGE")
boot_sectors=$(ceil_div "$boot_size" "$sector_size")
root_sectors=$(ceil_div "$root_size" "$sector_size")
boot_start=$first_sector
root_start=$(align_up $((boot_start + boot_sectors)) "$align_sectors")
root_end=$((root_start + root_sectors))
total_sectors=$(( $(align_up "$root_end" "$align_sectors") + 34 ))
total_bytes=$((total_sectors * sector_size))

tmp=$(mktemp "$(dirname "$OUTPUT_IMAGE")/.$(basename "$OUTPUT_IMAGE").XXXXXX")
trap 'rm -f "$tmp"' EXIT
truncate -s "$total_bytes" "$tmp"

sgdisk -o "$tmp" >/dev/null
sgdisk -n "1:${boot_start}:+${boot_sectors}" -t 1:ef00 -c 1:"$BOOT_PARTLABEL" -A 1:set:2 "$tmp" >/dev/null
sgdisk -n "2:${root_start}:+${root_sectors}" -t 2:8300 -c 2:"$ROOTFS_PARTLABEL" "$tmp" >/dev/null

dd if="$BOOT_IMAGE" of="$tmp" bs=4M conv=notrunc,fsync oflag=seek_bytes seek=$((boot_start * sector_size)) status=none
e2fsck -f -y "$ROOTFS_IMAGE"
if [ -n "${ROOTFS_UUID:-}" ]; then
  tune2fs -U "$ROOTFS_UUID" "$ROOTFS_IMAGE"
fi
dd if="$ROOTFS_IMAGE" of="$tmp" bs=4M conv=notrunc,fsync oflag=seek_bytes seek=$((root_start * sector_size)) status=none

mv "$tmp" "$OUTPUT_IMAGE"
trap - EXIT
sha256sum "$OUTPUT_IMAGE" > "$OUTPUT_IMAGE.sha256"
