#!/bin/bash
set -euo pipefail

# Verity Build Script
# Creates a minimal, locked-down Alpine Linux ISO that runs only nginx.

ALPINE_VERSION="3.21"
ALPINE_RELEASE="${ALPINE_VERSION}.0"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="/tmp/verity-build"
OUTPUT_DIR="$PROJECT_DIR/build"
ISO_NAME="verity.iso"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()   { echo -e "${GREEN}[verity]${NC} $1"; }
error() { echo -e "${RED}[verity]${NC} $1" >&2; exit 1; }

# --- Cleanup ---

cleanup() {
    log "Cleaning up..."
    umount "$WORK_DIR/rootfs/proc" 2>/dev/null || true
    umount "$WORK_DIR/rootfs/sys"  2>/dev/null || true
    umount "$WORK_DIR/rootfs/dev"  2>/dev/null || true
}
trap cleanup EXIT

# --- Checks ---

[ "$EUID" -eq 0 ] || error "Must run as root"

for cmd in wget xorriso mksquashfs cpio; do
    command -v "$cmd" >/dev/null || error "Missing dependency: $cmd"
done

# --- Workspace ---

log "Setting up workspace"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{rootfs,iso/boot/isolinux,initramfs/{bin,dev,proc,sys,tmp,newroot,lib/modules}}
mkdir -p "$OUTPUT_DIR"

# --- Download Alpine ---

ROOTFS_TAR="alpine-minirootfs-${ALPINE_RELEASE}-${ALPINE_ARCH}.tar.gz"
ROOTFS_URL="${ALPINE_MIRROR}/releases/${ALPINE_ARCH}/${ROOTFS_TAR}"
SHA256_URL="${ALPINE_MIRROR}/releases/${ALPINE_ARCH}/${ROOTFS_TAR}.sha256"

log "Downloading Alpine ${ALPINE_RELEASE}"
cd "$WORK_DIR"

if [ ! -f "$ROOTFS_TAR" ]; then
    wget -q "$ROOTFS_URL"    || error "Failed to download rootfs"
    wget -q "$SHA256_URL"     || error "Failed to download checksum"
    sha256sum -c "${ROOTFS_TAR}.sha256" || error "Checksum verification failed"
fi

log "Extracting rootfs"
tar xzf "$ROOTFS_TAR" -C rootfs/

# --- Chroot setup ---

mount -t proc none "$WORK_DIR/rootfs/proc"
mount -t sysfs none "$WORK_DIR/rootfs/sys"
mount -o bind /dev  "$WORK_DIR/rootfs/dev"
cp /etc/resolv.conf "$WORK_DIR/rootfs/etc/resolv.conf"

# --- Install packages ---

log "Installing packages"
chroot "$WORK_DIR/rootfs" /bin/sh <<'CHROOT_EOF'
set -e
apk update
apk add --no-cache \
    nginx \
    linux-lts \
    busybox-static \
    tzdata \
    ca-certificates
adduser -D -H -s /sbin/nologin nginx 2>/dev/null || true
mkdir -p /var/www/html /var/log/nginx /run/nginx
chown -R nginx:nginx /var/www/html /var/log/nginx /run/nginx
CHROOT_EOF

# --- Build initramfs ---
# Must happen BEFORE harden_system removes /boot and /lib/modules

log "Building initramfs"

# Copy kernel
VMLINUZ=$(ls "$WORK_DIR/rootfs/boot"/vmlinuz-lts 2>/dev/null) \
    || error "vmlinuz-lts not found — linux-lts failed to install"
cp "$VMLINUZ" "$WORK_DIR/iso/boot/vmlinuz"

# Copy busybox-static
cp "$WORK_DIR/rootfs/bin/busybox.static" "$WORK_DIR/initramfs/bin/busybox"

# Symlink busybox applets needed by initramfs-init
INITRAMFS="$WORK_DIR/initramfs"
for applet in sh mount umount mkdir sleep ls modprobe losetup switch_root; do
    ln -sf busybox "$INITRAMFS/bin/$applet"
done

# Copy kernel modules needed for boot
KVER=$(ls "$WORK_DIR/rootfs/lib/modules/" | head -1)
[ -n "$KVER" ] || error "No kernel modules found"

MODDIR="$INITRAMFS/lib/modules/$KVER"
mkdir -p "$MODDIR"

# Find and copy required modules + their dependencies
MODULES="squashfs loop isofs sr_mod cdrom virtio_blk virtio_pci virtio_scsi"
ROOTMOD="$WORK_DIR/rootfs/lib/modules/$KVER"

for mod in $MODULES; do
    find "$ROOTMOD" -name "${mod}.ko*" -exec cp {} "$MODDIR/" \; 2>/dev/null || true
done

# Copy module metadata for modprobe
for f in modules.dep modules.alias modules.symbols modules.builtin; do
    [ -f "$ROOTMOD/$f" ] && cp "$ROOTMOD/$f" "$MODDIR/" || true
done

# Run depmod for our subset
depmod -b "$INITRAMFS" "$KVER" 2>/dev/null || true

# Copy our init script
cp "$PROJECT_DIR/scripts/initramfs-init" "$INITRAMFS/init"
chmod +x "$INITRAMFS/init"

# Package as cpio.gz
log "Packaging initramfs"
(cd "$INITRAMFS" && find . | cpio -o -H newc 2>/dev/null | gzip -9) \
    > "$WORK_DIR/iso/boot/initramfs.gz"

[ -s "$WORK_DIR/iso/boot/initramfs.gz" ] || error "initramfs is empty"

# --- Copy configs ---

log "Copying configs"
cp "$PROJECT_DIR/config/nginx.conf"  "$WORK_DIR/rootfs/etc/nginx/nginx.conf"
cp "$PROJECT_DIR/config/sysctl.conf" "$WORK_DIR/rootfs/etc/sysctl.conf"
cp "$PROJECT_DIR/config/init"        "$WORK_DIR/rootfs/sbin/init"
chmod +x "$WORK_DIR/rootfs/sbin/init"

# Copy web content
if [ -d "$PROJECT_DIR/www" ] && ls "$PROJECT_DIR/www/"* >/dev/null 2>&1; then
    cp -r "$PROJECT_DIR/www/"* "$WORK_DIR/rootfs/var/www/html/"
fi
chroot "$WORK_DIR/rootfs" chown -R nginx:nginx /var/www/html

# --- Harden ---

log "Hardening system"
chroot "$WORK_DIR/rootfs" /bin/sh <<'CHROOT_EOF'
set -e

# Remove package manager
rm -f /sbin/apk /usr/bin/apk

# Remove kernel source + modules (already extracted to initramfs)
rm -rf /boot /lib/modules

# Remove unnecessary tools
rm -f /usr/bin/wget /usr/bin/curl /usr/bin/vi /usr/bin/nano
rm -f /usr/bin/strace /usr/bin/gdb

# Remove docs
rm -rf /usr/share/man /usr/share/doc

# Clear caches
rm -rf /var/cache/apk/* /tmp/*
CHROOT_EOF

# --- Unmount chroot ---

log "Unmounting chroot"
umount "$WORK_DIR/rootfs/proc"
umount "$WORK_DIR/rootfs/sys"
umount "$WORK_DIR/rootfs/dev"
# Disarm the trap since we cleaned up manually
trap - EXIT

# --- Create squashfs ---

log "Creating squashfs"
mksquashfs "$WORK_DIR/rootfs" "$WORK_DIR/iso/rootfs.squashfs" \
    -comp xz -noappend -quiet
[ -f "$WORK_DIR/iso/rootfs.squashfs" ] || error "squashfs creation failed"

# --- Bootloader ---

log "Setting up ISOLINUX"

cat > "$WORK_DIR/iso/boot/isolinux/isolinux.cfg" <<'EOF'
DEFAULT verity
LABEL verity
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.gz
    APPEND quiet
EOF

# Find isolinux.bin
ISOLINUX_BIN=""
for path in \
    /usr/lib/syslinux/bios/isolinux.bin \
    /usr/lib/ISOLINUX/isolinux.bin \
    /usr/share/syslinux/isolinux.bin; do
    [ -f "$path" ] && { ISOLINUX_BIN="$path"; break; }
done
[ -n "$ISOLINUX_BIN" ] || error "isolinux.bin not found — install syslinux"
cp "$ISOLINUX_BIN" "$WORK_DIR/iso/boot/isolinux/"

# Copy ldlinux.c32 if available (required by syslinux 5+)
for path in \
    /usr/lib/syslinux/bios/ldlinux.c32 \
    /usr/lib/syslinux/modules/bios/ldlinux.c32 \
    /usr/share/syslinux/ldlinux.c32; do
    [ -f "$path" ] && { cp "$path" "$WORK_DIR/iso/boot/isolinux/"; break; }
done

# --- Create ISO ---

log "Creating ISO"
xorriso -as mkisofs \
    -o "$OUTPUT_DIR/$ISO_NAME" \
    -V "VERITY" \
    -c boot/isolinux/boot.cat \
    -b boot/isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    "$WORK_DIR/iso/"

[ -f "$OUTPUT_DIR/$ISO_NAME" ] || error "ISO creation failed"

# --- Summary ---

log "Build complete!"
echo ""
echo "  ISO: $OUTPUT_DIR/$ISO_NAME"
echo "  Size: $(du -h "$OUTPUT_DIR/$ISO_NAME" | cut -f1)"
echo ""
echo "  Test: make test"
echo ""
