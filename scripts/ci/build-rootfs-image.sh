#!/usr/bin/env bash
set -euo pipefail

# Build an Arch Linux ARM aarch64 rootfs disk image for Lenovo Y700 (TB321FU).
#
# Instead of debootstrap (Ubuntu/Debian), this script uses the official
# ArchLinuxARM tarball as the base, then configures the system using
# Arch-native tools: pacman, systemd, locale.gen, etc.
#
# Required host tools: curl, tar, mount, umount, chroot, mkfs.ext4, e2fsck,
#   rsync, sha256sum, ar (from binutils, for extracting .deb firmware archives).

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build an Arch Linux ARM aarch64 rootfs disk image from declared inputs.

Required host tools: curl, tar, mount, umount, chroot, mkfs.ext4, e2fsck,
  rsync, sha256sum, ar (binutils).

Environment inputs:
  OUTPUT_DIR                 default: out/ci-rootfs
  OUTPUT_PREFIX              default: archlinuxarm-aarch64
  ALARM_TARBALL_URL          default: http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
  RESOLV_CONF_CONTENT        optional /etc/resolv.conf contents for chroot
  PACMAN_HTTP_PROXY          optional proxy used by pacman inside chroot
  PACMAN_HTTPS_PROXY         optional https proxy; defaults to PACMAN_HTTP_PROXY
  ROOTFS_IMAGE_SIZE          default: 14G
  ROOTFS_UUID                optional ext4 UUID
  ROOTFS_LABEL               default: ALARMROOTFS
  ROOTFS_PARTLABEL           metadata only, default: userdata
  HOSTNAME_NAME              default: y700
  DEFAULT_USER_NAME          default: alarm
  DEFAULT_USER_PASSWORD      default: alarm
  ROOT_PASSWORD              default: root
  USER_SUDO_MODE             password|nopasswd|none, default: nopasswd
  TZ_REGION                  default: Asia/Shanghai
  LANG_NAME                  default: zh_CN.UTF-8
  LOCALES                    default: en_US.UTF-8 UTF-8\\nzh_CN.UTF-8 UTF-8
  PACKAGE_LIST               optional: extra Arch packages to install (space-separated)
  DESKTOP_ENV                optional: desktop group/package appended to PACKAGE_LIST
  OVERLAY_ARCHIVE            optional local path or URL; extracted into rootfs
  OVERLAY_DIR                optional directory copied into rootfs
  FIRMWARE_ARCHIVE           optional archive with device-specific firmware (.deb or raw files)
  APPLY_Y700_FIRMWARE_FIXES  copy/verify required Y700 firmware paths, default: 1
  CLEAN_PACMAN_CACHE         default: 1
  COMPRESS                   none|zstd|xz|7z, default: 7z
  CHUNK_SIZE                 optional 7z volume size, example: 1500m
  KEEP_RAW_IMAGE             keep uncompressed rootfs image after packaging, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd curl
ci_require_cmd tar
ci_require_cmd mkfs.ext4
ci_require_cmd mount
ci_require_cmd umount
ci_require_cmd chroot
ci_require_cmd e2fsck
ci_require_cmd rsync
ci_require_cmd sha256sum

# --- Configuration defaults ---
ALARM_TARBALL_URL=${ALARM_TARBALL_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}
RESOLV_CONF_CONTENT=${RESOLV_CONF_CONTENT:-}
PACMAN_HTTP_PROXY=${PACMAN_HTTP_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}
PACMAN_HTTPS_PROXY=${PACMAN_HTTPS_PROXY:-${https_proxy:-${HTTPS_PROXY:-${PACMAN_HTTP_PROXY:-}}}}
OUTPUT_PREFIX=${OUTPUT_PREFIX:-archlinuxarm-aarch64}
OUTPUT_DIR=${OUTPUT_DIR:-out/ci-rootfs}
ROOTFS_IMAGE_SIZE=${ROOTFS_IMAGE_SIZE:-14G}
ROOTFS_LABEL=${ROOTFS_LABEL:-ALARMROOTFS}
ROOTFS_PARTLABEL=${ROOTFS_PARTLABEL:-userdata}
HOSTNAME_NAME=${HOSTNAME_NAME:-y700}
DEFAULT_USER_NAME=${DEFAULT_USER_NAME:-alarm}
DEFAULT_USER_PASSWORD=${DEFAULT_USER_PASSWORD:-alarm}
ROOT_PASSWORD=${ROOT_PASSWORD:-root}
USER_SUDO_MODE=${USER_SUDO_MODE:-nopasswd}
TZ_REGION=${TZ_REGION:-Asia/Shanghai}
LANG_NAME=${LANG_NAME:-zh_CN.UTF-8}
LOCALES=${LOCALES:-$'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8'}
CLEAN_PACMAN_CACHE=${CLEAN_PACMAN_CACHE:-1}
APPLY_Y700_FIRMWARE_FIXES=${APPLY_Y700_FIRMWARE_FIXES:-1}
COMPRESS=${COMPRESS:-7z}
CHUNK_SIZE=${CHUNK_SIZE:-1500m}
KEEP_RAW_IMAGE=${KEEP_RAW_IMAGE:-0}

# Arch Linux ARM base system already includes: systemd, dbus, pacman, util-linux,
# coreutils, bash, iproute2, etc. We add packages that a typical desktop/tablet
# user would need. Unlike Ubuntu's debootstrap minbase, the ALARM tarball already
# provides a complete base system, so the package list is purely additive.
#
# Note: linux-firmware is intentionally NOT included here because it's ~400MB+
# compressed. Device-specific firmware (GPU, audio topology, VPU) comes from
# FIRMWARE_ARCHIVE instead. Users can add it to PACKAGE_LIST if needed.
default_packages="sudo networkmanager openssh nano vim less man-db man-pages curl wget rsync kmod mkinitcpio haveged"
PACKAGE_LIST=${PACKAGE_LIST:-$default_packages}
if [ -n "${DESKTOP_ENV:-}" ]; then
  PACKAGE_LIST="$PACKAGE_LIST $DESKTOP_ENV"
fi

mkdir -p "$OUTPUT_DIR"
work_dir=$(mktemp -d "$OUTPUT_DIR/.rootfs-build.XXXXXX")
rootfs_dir="$work_dir/rootfs"
rootfs_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.img"
manifest="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.manifest"
mounted=0

# --- Y700 firmware path fixes ---
# The kernel looks for firmware in /lib/firmware/qcom/ canonical paths, but
# vendor packages may install them elsewhere. This function creates the
# expected symlinks or copies. Same firmware binary blobs, Arch paths.
apply_y700_firmware_fixes() {
  local root=$1

  ci_log "applying Y700 firmware path fixes"

  install -d -m 0755 "$root/lib/firmware/qcom" "$root/lib/firmware/qcom/sm8650" "$root/lib/firmware/qcom/vpu"

  copy_firmware_if_missing() {
    local source_rel=$1
    local dest_rel=$2
    [ -f "$root/$source_rel" ] || return 1
    if [ -e "$root/$dest_rel" ]; then
      return 0
    fi
    install -d -m 0755 "$(dirname "$root/$dest_rel")"
    install -m 0644 "$root/$source_rel" "$root/$dest_rel"
  }

  # GPU firmware: kernel expects /lib/firmware/qcom/gen70900_zap.mbn
  local src dst
  for src in \
    usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn \
    lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn; do
    if copy_firmware_if_missing "$src" lib/firmware/qcom/gen70900_zap.mbn; then
      break
    fi
  done

  # Audio topology: kernel expects /lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
  for src in \
    usr/lib/firmware/qcom-tb321fu/Lenovo-Y700-TB321FU-tplg.bin \
    lib/firmware/qcom-tb321fu/Lenovo-Y700-TB321FU-tplg.bin; do
    if copy_firmware_if_missing "$src" lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin; then
      break
    fi
  done

  # Additional GPU/VPU firmware from vendor paths to canonical /lib/firmware
  for src in \
    usr/lib/firmware/qcom/gen70900_aqe.fw \
    usr/lib/firmware/qcom/gen70900_sqe.fw \
    usr/lib/firmware/qcom/gmu_gen70900.bin \
    usr/lib/firmware/qcom/vpu/vpu33_p4.mbn; do
    dst=${src#usr/}
    copy_firmware_if_missing "$src" "$dst" || true
  done

  local required=(
    lib/firmware/qcom/gen70900_aqe.fw
    lib/firmware/qcom/gen70900_sqe.fw
    lib/firmware/qcom/gen70900_zap.mbn
    lib/firmware/qcom/gmu_gen70900.bin
    lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
    lib/firmware/qcom/vpu/vpu33_p4.mbn
  )
  local rel
  for rel in "${required[@]}"; do
    [ -e "$root/$rel" ] || [ -L "$root/$rel" ] || ci_die "missing Y700 required compatibility file: $rel"
  done
}

# --- Extract firmware from .deb files ---
# The FIRMWARE_ARCHIVE may contain .deb packages (Debian archive format).
# Since Arch doesn't have dpkg, we manually extract the data payload from
# each .deb using ar + tar. A .deb is an ar archive containing:
#   debian-binary, control.tar.*, data.tar.*
# We extract data.tar.* to get the actual files (firmware, modules, etc.).
extract_deb_to_rootfs() {
  local deb_file=$1
  local root=$2
  local deb_work
  deb_work=$(mktemp -d "$work_dir/.deb-extract.XXXXXX")

  ci_log "extracting .deb: $(basename "$deb_file")"

  # Extract the ar archive (which contains debian-binary, control.tar.*, data.tar.*)
  if ! ar x "$deb_file" --output="$deb_work" 2>/dev/null; then
    ci_log "WARNING: failed to extract .deb with ar, skipping: $(basename "$deb_file")"
    rm -rf "$deb_work"
    return 0
  fi

  # Find and extract the data tarball
  local data_tar
  data_tar=$(find "$deb_work" -maxdepth 1 -name 'data.tar.*' | head -n1 || true)
  if [ -z "$data_tar" ]; then
    ci_log "WARNING: no data.tar.* found in .deb, skipping: $(basename "$deb_file")"
    rm -rf "$deb_work"
    return 0
  fi

  # Extract data.tar into rootfs
  case "$data_tar" in
    *.tar.gz|*.tgz) tar -C "$root" -xzf "$data_tar" ;;
    *.tar.xz) tar -C "$root" -xJf "$data_tar" ;;
    *.tar.zst) tar -C "$root" --zstd -xf "$data_tar" ;;
    *.tar) tar -C "$root" -xf "$data_tar" ;;
    *) ci_log "WARNING: unknown data.tar format, skipping: $data_tar" ;;
  esac

  rm -rf "$deb_work"
}

# --- Cleanup ---
cleanup() {
  set +e
  if [ "$mounted" = 1 ]; then
    for p in dev/pts dev proc sys run; do
      mountpoint -q "$rootfs_dir/$p" && umount -l "$rootfs_dir/$p"
    done
    mountpoint -q "$rootfs_dir" && umount "$rootfs_dir"
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

# --- Step 1: Create the ext4 image ---
ci_log "creating ext4 image: $rootfs_img"
rm -f "$rootfs_img"
truncate -s "$ROOTFS_IMAGE_SIZE" "$rootfs_img"
mkfs_args=(-F -L "$ROOTFS_LABEL")
if [ -n "${ROOTFS_UUID:-}" ]; then
  mkfs_args+=(-U "$ROOTFS_UUID")
fi
mkfs.ext4 "${mkfs_args[@]}" "$rootfs_img"

mkdir -p "$rootfs_dir"
mount -o loop "$rootfs_img" "$rootfs_dir"
mounted=1

# --- Step 2: Download and extract the Arch Linux ARM rootfs tarball ---
# Unlike Ubuntu's debootstrap which bootstraps from scratch, Arch Linux ARM
# distributes a pre-built rootfs tarball. We download it and extract directly.
alarm_tarball="$work_dir/ArchLinuxARM-aarch64-latest.tar.gz"
ci_log "downloading Arch Linux ARM tarball from $ALARM_TARBALL_URL"
ci_download "$ALARM_TARBALL_URL" "$alarm_tarball"

ci_log "extracting Arch Linux ARM rootfs"
tar -C "$rootfs_dir" -xzf "$alarm_tarball"

# --- Step 3: Apply firmware from FIRMWARE_ARCHIVE BEFORE chroot ---
# This must happen before chroot so that:
#   1. Firmware files are in place for apply_y700_firmware_fixes
#   2. .deb files can be extracted on the host using `ar` (no dpkg needed in chroot)
#   3. Any tar overlay files from the archive are also applied early
#
# The FIRMWARE_ARCHIVE may contain:
#   - .deb files (Debian packages with firmware) → extracted via ar + tar
#   - .tar/.tar.gz/.tar.xz/.tar.zst overlay files → extracted directly into rootfs
#   - Raw firmware files → copied into rootfs
if [ -n "${FIRMWARE_ARCHIVE:-}" ]; then
  tmp_fw_archive="$work_dir/firmware.archive"
  fw_extract_dir="$work_dir/firmware-extracted"
  mkdir -p "$fw_extract_dir"
  ci_log "downloading firmware archive: $FIRMWARE_ARCHIVE"
  ci_download "$FIRMWARE_ARCHIVE" "$tmp_fw_archive"
  ci_extract_archive "$tmp_fw_archive" "$fw_extract_dir"

  ci_log "processing firmware archive contents"

  # Process .deb files: extract firmware from each one
  local_debs=$(find "$fw_extract_dir" -maxdepth 2 -type f -name '*.deb' 2>/dev/null || true)
  if [ -n "$local_debs" ]; then
    ci_require_cmd ar
    echo "$local_debs" | while IFS= read -r deb_file; do
      [ -f "$deb_file" ] || continue
      extract_deb_to_rootfs "$deb_file" "$rootfs_dir"
    done
  fi

  # Process tar overlay files (same as Ubuntu's approach for ci-debs/*.tar*)
  for overlay_file in \
    "$fw_extract_dir"/*.tar \
    "$fw_extract_dir"/*.tar.gz \
    "$fw_extract_dir"/*.tgz \
    "$fw_extract_dir"/*.tar.xz \
    "$fw_extract_dir"/*.tar.zst; do
    [ -e "$overlay_file" ] || continue
    ci_log "applying firmware overlay: $(basename "$overlay_file")"
    case "$overlay_file" in
      *.tar) tar -C "$rootfs_dir" -xf "$overlay_file" ;;
      *.tar.gz|*.tgz) tar -C "$rootfs_dir" -xzf "$overlay_file" ;;
      *.tar.xz) tar -C "$rootfs_dir" -xJf "$overlay_file" ;;
      *.tar.zst) tar -C "$rootfs_dir" --zstd -xf "$overlay_file" ;;
    esac
  done

  # Copy any remaining raw firmware files directly
  # (files that aren't .deb or .tar*)
  other_files=$(find "$fw_extract_dir" -maxdepth 1 -type f \
    ! -name '*.deb' ! -name '*.tar' ! -name '*.tar.gz' ! -name '*.tgz' \
    ! -name '*.tar.xz' ! -name '*.tar.zst' 2>/dev/null || true)
  if [ -n "$other_files" ]; then
    ci_log "copying raw firmware files"
    # These could be directories or files; copy them into rootfs/lib/firmware/
    mkdir -p "$rootfs_dir/lib/firmware"
    # shellcheck disable=SC2086
    cp -a $other_files "$rootfs_dir/lib/firmware/" 2>/dev/null || true
  fi
fi

# --- Step 4: Prepare chroot environment ---
# Save original resolv.conf state
original_resolv="$work_dir/resolv.conf.original"
original_resolv_link="$work_dir/resolv.conf.link"
if [ -L "$rootfs_dir/etc/resolv.conf" ]; then
  readlink "$rootfs_dir/etc/resolv.conf" > "$original_resolv_link"
elif [ -e "$rootfs_dir/etc/resolv.conf" ]; then
  cp -a "$rootfs_dir/etc/resolv.conf" "$original_resolv"
fi

# Write a working resolv.conf for chroot operations
rm -f "$rootfs_dir/etc/resolv.conf"
if [ -n "$RESOLV_CONF_CONTENT" ]; then
  printf '%s\n' "$RESOLV_CONF_CONTENT" > "$rootfs_dir/etc/resolv.conf"
elif [ -f /run/systemd/resolve/resolv.conf ]; then
  cp /run/systemd/resolve/resolv.conf "$rootfs_dir/etc/resolv.conf"
elif [ -f /etc/resolv.conf ]; then
  cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"
else
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$rootfs_dir/etc/resolv.conf"
fi
# Ensure at least one non-loopback nameserver exists
if ! awk '
  /^[[:space:]]*nameserver[[:space:]]+/ {
    ns=$2
    if (ns !~ /^(127\.|::1$|0\.0\.0\.0$)/) good=1
  }
  END { exit good ? 0 : 1 }
' "$rootfs_dir/etc/resolv.conf"; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$rootfs_dir/etc/resolv.conf"
fi

# Mount virtual filesystems for chroot
mount --bind /dev "$rootfs_dir/dev"
mount --bind /dev/pts "$rootfs_dir/dev/pts"
mount -t proc proc "$rootfs_dir/proc"
mount -t sysfs sysfs "$rootfs_dir/sys"
mount -t tmpfs tmpfs "$rootfs_dir/run"

# --- Step 5: Write the in-chroot provisioning script ---
# This script runs INSIDE the Arch Linux ARM rootfs using chroot.
# It uses Arch-native tools: pacman, systemctl, locale-gen, etc.
# It does NOT use any Debian/Ubuntu-specific commands.
cat > "$rootfs_dir/root/ci-provision.sh" <<'PROVISION'
#!/usr/bin/env bash
set -euo pipefail

# --- Configure pacman proxy (if needed) ---
# Arch uses /etc/pacman.d/mirrorlist and a different proxy mechanism than apt.
if [ -n "${PACMAN_HTTP_PROXY:-}" ] || [ -n "${PACMAN_HTTPS_PROXY:-}" ]; then
  # pacman uses XferCommand for proxy, or we set environment vars
  # The simplest approach: set the environment and let curl/wget handle it
  if [ -n "${PACMAN_HTTP_PROXY:-}" ]; then
    export http_proxy="$PACMAN_HTTP_PROXY"
    export HTTP_PROXY="$PACMAN_HTTP_PROXY"
  fi
  if [ -n "${PACMAN_HTTPS_PROXY:-}" ]; then
    export https_proxy="$PACMAN_HTTPS_PROXY"
    export HTTPS_PROXY="$PACMAN_HTTPS_PROXY"
  fi
fi

# --- Initialize pacman keyring ---
# Arch Linux ARM ships with an unpopulated keyring in the tarball.
# This is a critical step that has no Ubuntu equivalent.
echo "Initializing pacman keyring..."
# haveged provides entropy for pacman-key --init (can be slow without it)
haveged -F &
HAVEGED_PID=$!
pacman-key --init
pacman-key --populate archlinuxarm
kill "$HAVEGED_PID" 2>/dev/null || true

# --- Update system ---
echo "Updating system packages..."
pacman -Syu --noconfirm

# --- Install additional packages ---
if [ -n "$PACKAGE_LIST" ]; then
  echo "Installing packages: $PACKAGE_LIST"
  # shellcheck disable=SC2086
  pacman -S --noconfirm --needed $PACKAGE_LIST || true
fi

# --- Enable services ---
# Arch uses systemctl the same way, but service names differ from Ubuntu.
systemctl enable NetworkManager.service || true
systemctl enable sshd.service || true
# haveged is useful for maintaining entropy on first boot too
systemctl enable haveged.service || true

# --- Configure default user ---
# Arch Linux ARM already ships with user 'alarm' (uid 1000).
# We ensure the user exists and configure it as requested.
if ! id -u "$DEFAULT_USER_NAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEFAULT_USER_NAME"
fi

# Set user password
echo "$DEFAULT_USER_NAME:$DEFAULT_USER_PASSWORD" | chpasswd

# --- Configure sudo for the default user ---
# This is a key requirement: give the alarm user sudo access.
# Arch uses the 'wheel' group for sudo, not 'sudo' like Ubuntu.
case "$USER_SUDO_MODE" in
  password)
    # Add user to wheel group; sudo requires password
    usermod -aG wheel "$DEFAULT_USER_NAME"
    # Ensure wheel group is enabled in sudoers (uncomment the line)
    sed -i 's/^# *\(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers
    # Remove any existing nopasswd override
    rm -f "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  nopasswd)
    # Add user to wheel group with NOPASSWD
    usermod -aG wheel "$DEFAULT_USER_NAME"
    mkdir -p /etc/sudoers.d
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEFAULT_USER_NAME" > "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    chmod 0440 "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  none)
    # Remove from wheel group, remove sudoers.d overrides
    gpasswd -d "$DEFAULT_USER_NAME" wheel >/dev/null 2>&1 || true
    rm -f "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  *)
    echo "unsupported USER_SUDO_MODE=$USER_SUDO_MODE" >&2
    exit 1
    ;;
esac

# --- Configure root password ---
# Arch Linux ARM tarball ships with root password 'root'.
# Override if a different password is specified.
echo "root:$ROOT_PASSWORD" | chpasswd

# --- Configure hostname ---
# Set hostname before other operations that might need it
printf '%s\n' "$HOSTNAME_NAME" > /etc/hostname

# Ensure /etc/hosts has an entry for the hostname
if ! grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
  printf '127.0.1.1\t%s\n' "$HOSTNAME_NAME" >> /etc/hosts
fi

# --- Configure timezone ---
# Arch way: symlink /etc/localtime and write /etc/timezone
if [ -n "$TZ_REGION" ] && [ -f "/usr/share/zoneinfo/$TZ_REGION" ]; then
  ln -sf "/usr/share/zoneinfo/$TZ_REGION" /etc/localtime
  # Also write /etc/timezone for compatibility
  printf '%s\n' "$TZ_REGION" > /etc/timezone
fi

# --- Configure locale ---
# Arch uses /etc/locale.gen (same format as Debian) and locale-gen command,
# but there's no update-locale. Instead we write /etc/locale.conf directly.
while IFS= read -r locale_line; do
  [ -n "$locale_line" ] || continue
  sed -i "s/^# *\($locale_line\)/\1/" /etc/locale.gen || true
done <<LOCALES_EOF
$LOCALES
LOCALES_EOF
locale-gen

# Set system locale via /etc/locale.conf (Arch way, no update-locale)
printf 'LANG=%s\n' "$LANG_NAME" > /etc/locale.conf
# Also set for this session so subsequent commands work
export LANG="$LANG_NAME"

# --- Clean pacman cache ---
if [ "$CLEAN_PACMAN_CACHE" = 1 ]; then
  pacman -Sc --noconfirm || true
  rm -rf /var/cache/pacman/pkg/*
fi

# --- Cleanup ---
rm -f /etc/machine-id
touch /etc/machine-id
rm -f /root/.bash_history "/home/${DEFAULT_USER_NAME}/.bash_history"
rm -rf /tmp/* /root/ci-provision.sh
PROVISION
chmod +x "$rootfs_dir/root/ci-provision.sh"

# --- Step 6: Run the provisioning script in chroot ---
# Use plain chroot (not arch-chroot) because we manage resolv.conf and
# mount points ourselves. arch-chroot would conflict with our manual setup.
ci_log "provisioning Arch Linux ARM rootfs"

chroot "$rootfs_dir" env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root \
  LANG=C.UTF-8 \
  PACKAGE_LIST="$PACKAGE_LIST" \
  DEFAULT_USER_NAME="$DEFAULT_USER_NAME" \
  DEFAULT_USER_PASSWORD="$DEFAULT_USER_PASSWORD" \
  ROOT_PASSWORD="$ROOT_PASSWORD" \
  USER_SUDO_MODE="$USER_SUDO_MODE" \
  TZ_REGION="$TZ_REGION" \
  LOCALES="$LOCALES" \
  LANG_NAME="$LANG_NAME" \
  PACMAN_HTTP_PROXY="$PACMAN_HTTP_PROXY" \
  PACMAN_HTTPS_PROXY="$PACMAN_HTTPS_PROXY" \
  CLEAN_PACMAN_CACHE="$CLEAN_PACMAN_CACHE" \
  bash /root/ci-provision.sh

# --- Step 7: Restore resolv.conf ---
rm -f "$rootfs_dir/etc/resolv.conf"
if [ -f "$original_resolv_link" ]; then
  ln -s "$(cat "$original_resolv_link")" "$rootfs_dir/etc/resolv.conf"
elif [ -f "$original_resolv" ]; then
  cp -a "$original_resolv" "$rootfs_dir/etc/resolv.conf"
else
  # Arch Linux ARM default: systemd-resolved stub
  ln -sf /run/systemd/resolve/stub-resolv.conf "$rootfs_dir/etc/resolv.conf"
fi

# --- Step 8: Apply overlay ---
if [ -n "${OVERLAY_ARCHIVE:-}" ]; then
  tmp_overlay="$work_dir/overlay.archive"
  ci_log "applying overlay archive: $OVERLAY_ARCHIVE"
  ci_download "$OVERLAY_ARCHIVE" "$tmp_overlay"
  ci_extract_archive "$tmp_overlay" "$rootfs_dir"
fi
if [ -n "${OVERLAY_DIR:-}" ]; then
  ci_log "applying overlay directory: $OVERLAY_DIR"
  rsync -aH --numeric-ids "$OVERLAY_DIR"/ "$rootfs_dir"/
fi

# --- Step 9: Apply Y700 firmware fixes ---
# This runs AFTER firmware archive extraction, so the firmware files
# should already be in place from Step 3.
if ci_bool "$APPLY_Y700_FIRMWARE_FIXES"; then
  apply_y700_firmware_fixes "$rootfs_dir"
fi

# --- Step 10: Write build info ---
cat > "$rootfs_dir/BUILD-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
distro=archlinuxarm
arch=aarch64
alarm_tarball_url=$ALARM_TARBALL_URL
hostname=$HOSTNAME_NAME
default_user=$DEFAULT_USER_NAME
user_sudo_mode=$USER_SUDO_MODE
rootfs_label=$ROOTFS_LABEL
rootfs_uuid=${ROOTFS_UUID:-}
rootfs_partlabel=$ROOTFS_PARTLABEL
overlay_archive=${OVERLAY_ARCHIVE:-}
overlay_dir=${OVERLAY_DIR:-}
firmware_archive=${FIRMWARE_ARCHIVE:-}
apply_y700_firmware_fixes=$APPLY_Y700_FIRMWARE_FIXES
INFO

# --- Step 11: Write manifest ---
ci_log "writing manifest"
(cd "$rootfs_dir" && find . -xdev -printf '%y\t%u\t%g\t%m\t%s\t%p\n' | sort) > "$manifest"

# --- Step 12: Unmount and finalize image ---
for p in dev/pts dev proc sys run; do
  mountpoint -q "$rootfs_dir/$p" && umount -l "$rootfs_dir/$p"
done
umount "$rootfs_dir"
mounted=0
e2fsck -f -y "$rootfs_img"

# --- Step 13: Checksum and compress ---
ci_log "checksumming rootfs image"
raw_sha_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.raw.sha256"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" > "$(basename "$raw_sha_file")")

checksum_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.SHA256SUMS"
rm -f "$checksum_file"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$manifest")" "$(basename "$raw_sha_file")" > "$(basename "$checksum_file")")

case "$COMPRESS" in
  none)
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" >> "$(basename "$checksum_file")")
    ;;
  zstd)
    ci_require_cmd zstd
    zstd -T0 -19 -f "$rootfs_img" -o "$rootfs_img.zst"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img").zst" >> "$(basename "$checksum_file")")
    ;;
  xz)
    xz -T0 -k -f "$rootfs_img"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img").xz" >> "$(basename "$checksum_file")")
    ;;
  7z)
    ci_require_cmd 7z
    sevenz_out="$rootfs_img.7z"
    rm -f "$sevenz_out" "$sevenz_out".*
    if [ -n "${CHUNK_SIZE:-}" ]; then
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on "-v$CHUNK_SIZE" >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")".* >> "$(basename "$checksum_file")")
    else
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")" >> "$(basename "$checksum_file")")
    fi
    ;;
  *) ci_die "unsupported COMPRESS=$COMPRESS" ;;
esac

if [ "$COMPRESS" != none ] && [ "$KEEP_RAW_IMAGE" != 1 ]; then
  rm -f "$rootfs_img"
fi

ci_log "Arch Linux ARM rootfs build complete: $OUTPUT_DIR"
