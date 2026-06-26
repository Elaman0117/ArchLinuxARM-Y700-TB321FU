# Arch Linux ARM for Lenovo Y700 (TB321FU)

GitHub Actions CI for building Arch Linux ARM aarch64 rootfs and GRUB/FAT boot images for the Lenovo Y700 2025 (TB321FU) tablet.

This repository is **inspired by** the [Ubuntu Y700 Build CI](https://github.com/Elaman0117/Arch-Linux-ARM-for-Y700-2025), but **completely re-engineered** from scratch for Arch Linux ARM. Every build step has been reconsidered for the Arch Linux ecosystem — no Ubuntu/Debian-specific tools (debootstrap, apt, dpkg) are used.

## Key Differences from the Ubuntu Version

| Aspect | Ubuntu Original | Arch Linux ARM (This Repo) |
|--------|----------------|---------------------------|
| Rootfs source | `debootstrap` from Ubuntu ports mirror | Official ArchLinuxARM tarball from `os.archlinuxarm.org` |
| Package manager | `apt-get` | `pacman` |
| Keyring init | Not needed (debootstrap handles it) | `pacman-key --init` + `pacman-key --populate archlinuxarm` |
| Default user | `y700` (created via `useradd`) | `alarm` (pre-existing in tarball, configured via `usermod`) |
| Sudo group | `sudo` group | `wheel` group |
| Locale config | `update-locale` command | Direct `/etc/locale.conf` write |
| Timezone config | `dpkg-reconfigure tzdata` | Symlink + `/etc/timezone` write |
| Device firmware | `.deb` packages via `dpkg -i` | `.deb` extracted via `ar` + `tar` (no dpkg needed), plus raw firmware files |
| Initramfs | `initramfs-tools` | Not used (Y700 boots kernel directly via GRUB, no initrd) |
| Entropy for keyring | N/A | `haveged` started during `pacman-key --init` |
| Root password | Locked by default | Set (default: `root`) |
| Proxy support | `APT_HTTP_PROXY` | `PACMAN_HTTP_PROXY` |

## Workflow

Primary workflow: `.github/workflows/build-rootfs-and-grub.yml`

It has four dispatch inputs:

- `release_tag`: optional release tag to upload artifacts to.
- `output_prefix`: output filename prefix.
- `rootfs_config`: rootfs settings as `KEY=value` lines.
- `boot_config`: GRUB/FAT boot settings as `KEY=value` lines.
- `source_config`: input artifact URLs as `KEY=value` lines.

## Rootfs Config

Example:

```text
ALARM_TARBALL_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
ROOTFS_IMAGE_SIZE=20G
ROOTFS_UUID=
ROOTFS_LABEL=ALARMROOTFS
ROOTFS_PARTLABEL=userdata
HOSTNAME_NAME=y700
DEFAULT_USER_NAME=alarm
DEFAULT_USER_PASSWORD=alarm
ROOT_PASSWORD=root
USER_SUDO_MODE=nopasswd
TZ_REGION=Asia/Shanghai
LANG_NAME=zh_CN.UTF-8
PACKAGE_LIST=
DESKTOP_ENV=
OVERLAY_ARCHIVE=
FIRMWARE_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-device-debs-20260624-201420-compat1.tar.gz
APPLY_Y700_FIRMWARE_FIXES=1
CLEAN_PACMAN_CACHE=1
COMPRESS=7z
CHUNK_SIZE=1500m
KEEP_RAW_IMAGE=0
```

## Boot Config

Example:

```text
BOOT_TEMPLATE_IMAGE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-verified-grub-template-userdata-20260624-201420.img
BOOT_IMAGE_SIZE=256M
BOOT_FAT_BITS=32
BOOT_FAT_LABEL=ALARMGRUB
BOOT_SECTOR_SIZE=512
BOOT_CLUSTER_SECTORS=
ROOT_SELECTOR=partlabel
ROOT_PARTLABEL=userdata
ROOT_UUID=
ROOTARGS=
ROOTARGS_EXTRA=
STABLEARGS=drm_client_lib.active=none
BOOT_COMPRESS=7z
BOOT_CHUNK_SIZE=1500m
KEEP_BOOT_IMAGE=0
```

## Source Config

Example:

```text
KERNEL_ARTIFACT_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-kernel-artifacts-7.1.1-g5df8e852ea72.tar.gz
BOOTAA64_EFI_URL=
QCOMRAMP_EFI_URL=
QCOMRAMP_CFG_NAME=qcomramp.cfg
GRUB_BUILD_ARCHIVE=
DTB_NAME=sm8650-lenovo-tb321fu.dtb
```

## Scripts

- `scripts/ci/build-rootfs-image.sh`: builds an ext4 rootfs image from the official ArchLinuxARM tarball. Uses `pacman` for package management, `pacman-key` for keyring initialization, and Arch-native configuration tools.
- `scripts/ci/build-grub-image.sh`: builds a FAT boot image containing BOOTAA64.EFI, QCOMRAMP.EFI, Image, DTB and GRUB config. Boot parameters are tuned for Arch Linux ARM (e.g., `init=/sbin/init`).
- `scripts/ci/pack-disk-image.sh`: optional GPT disk image packer for a FAT boot image plus ext4 rootfs image.
- `scripts/ci/apply-workflow-config.sh`: validates dispatch config blocks and exports allowed keys into the workflow environment.
- `scripts/lib/y700-direct-grub.sh`: device-specific GRUB helpers for Qualcomm direct-boot (unchanged from Ubuntu version, as this is hardware-specific).

## Build Process Overview

### Rootfs (Arch Linux ARM way)

1. **Download**: Fetch the official `ArchLinuxARM-aarch64-latest.tar.gz` from `os.archlinuxarm.org`.
2. **Create image**: Make an ext4 filesystem image and mount it.
3. **Extract**: Extract the tarball into the mounted image (replaces `debootstrap`).
4. **Firmware extraction** (before chroot): Download and extract `FIRMWARE_ARCHIVE`. If it contains `.deb` packages, extract their `data.tar.*` payload using `ar` + `tar` (no dpkg needed). Also handles raw firmware files and `.tar*` overlays.
5. **Chroot setup**: Mount `/dev`, `/proc`, `/sys`, `/run` and prepare `resolv.conf`.
6. **Provision** (in chroot):
   - Start `haveged` for entropy
   - Initialize pacman keyring: `pacman-key --init && pacman-key --populate archlinuxarm`
   - Update system: `pacman -Syu`
   - Install packages: `pacman -S --needed sudo networkmanager openssh haveged ...`
   - Enable services: `systemctl enable NetworkManager sshd haveged`
   - Configure `alarm` user: add to `wheel` group, set password, configure sudo
   - Set timezone via symlink + `/etc/timezone`
   - Set locale via `/etc/locale.gen` + `locale-gen` + `/etc/locale.conf`
7. **Firmware fixes**: Apply Y700-specific firmware path fixes (copies firmware to canonical `/lib/firmware/qcom/` paths).
8. **Finalize**: Unmount, `e2fsck`, checksum, compress.

> **Note**: No initramfs is generated because the Y700 boots the kernel Image directly via GRUB without an initrd. The `mkinitcpio` package is installed for users who may want to add an initramfs later.

### Boot Image (device-specific, mostly distro-agnostic)

1. **Prepare payload**: Collect kernel Image, DTB, EFI binaries.
2. **GRUB config**: Write Arch Linux ARM compatible boot parameters.
3. **Assemble**: Either use a verified template image or create fresh FAT32 image.
4. **Compress**: 7z with volume splitting.

## Default Credentials

| Account | Username | Password |
|---------|----------|----------|
| User | `alarm` | `alarm` |
| Root | `root` | `root` |

The `alarm` user has passwordless sudo by default (`USER_SUDO_MODE=nopasswd`).

## Policy Boundary

The rootfs builder does not hardcode one historical verified Y700 state. Use `OVERLAY_ARCHIVE`, `FIRMWARE_ARCHIVE`, and the source artifact inputs to select the device payload for each build. Separate verification profiles can be added as independent workflow steps without making the rootfs construction script depend on one fixed baseline.
