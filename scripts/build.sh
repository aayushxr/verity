#!/bin/bash
set -euo pipefail

# Verity Build Script
# Creates a minimal, locked-down Alpine Linux ISO that runs only nginx.
# Output: hybrid BIOS+UEFI bootable ISO, plus PXE artifacts in build/pxe/.

ALPINE_VERSION="3.21"
ALPINE_RELEASE="${ALPINE_VERSION}.0"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="/tmp/verity-build"
OUTPUT_DIR="$PROJECT_DIR/build"
PXE_DIR="$OUTPUT_DIR/pxe"
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

# --- Auto-install build dependencies ---
# Each entry is "binary:apk_pkg:apt_pkg:dnf_pkg". We probe for the binary;
# if missing, we install via whichever package manager is available.

DEPS="
    wget:wget:wget:wget
    xorriso:xorriso:xorriso:xorriso
    mksquashfs:squashfs-tools:squashfs-tools:squashfs-tools
    cpio:cpio:cpio:cpio
    mkfs.vfat:dosfstools:dosfstools:dosfstools
    mcopy:mtools:mtools:mtools
    mmd:mtools:mtools:mtools
    grub-mkstandalone:grub-efi:grub-efi-amd64-bin:grub2-efi-x64-modules
    depmod:kmod:kmod:kmod
    isohybrid:syslinux:syslinux-utils:syslinux
"

detect_pm() {
    if   command -v apk >/dev/null; then echo apk
    elif command -v apt-get >/dev/null; then echo apt
    elif command -v dnf >/dev/null; then echo dnf
    elif command -v yum >/dev/null; then echo yum
    else echo ""
    fi
}

install_pkgs() {
    local pm="$1"; shift
    case "$pm" in
        apk) apk add --no-cache "$@" ;;
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq \
             && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
    esac
}

PM=$(detect_pm)
MISSING=""
for entry in $DEPS; do
    bin="${entry%%:*}"
    rest="${entry#*:}"
    apk_pkg="${rest%%:*}"; rest="${rest#*:}"
    apt_pkg="${rest%%:*}"; rest="${rest#*:}"
    dnf_pkg="${rest%%:*}"
    if ! command -v "$bin" >/dev/null; then
        case "$PM" in
            apk) MISSING="$MISSING $apk_pkg" ;;
            apt) MISSING="$MISSING $apt_pkg" ;;
            dnf|yum) MISSING="$MISSING $dnf_pkg" ;;
            "") error "Missing dependency: $bin (and no supported package manager: apk/apt/dnf/yum)" ;;
        esac
    fi
done

if [ -n "$MISSING" ]; then
    log "Installing build deps via $PM:$MISSING"
    install_pkgs "$PM" $MISSING || error "Failed to install build deps via $PM"
fi

# Final verification — every binary must now be on PATH.
for entry in $DEPS; do
    bin="${entry%%:*}"
    command -v "$bin" >/dev/null \
        || error "Dependency still missing after install: $bin"
done

# --- Workspace ---

log "Setting up workspace"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{rootfs,iso/boot/{isolinux,grub},initramfs/{bin,dev,proc,sys,tmp,newroot,lib/modules,lib/firmware,etc}}
mkdir -p "$OUTPUT_DIR" "$PXE_DIR"

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
# kmod gives us modprobe + depmod for dependency resolution in the build env.
# Firmware subpackages cover common server NICs (Broadcom, Intel, Mellanox,
# Chelsio, QLogic, Marvell, Netronome).

log "Installing packages"
chroot "$WORK_DIR/rootfs" /bin/sh <<'CHROOT_EOF'
set -e
apk update

# Required base packages — fail loud if any are missing.
apk add --no-cache \
    nginx \
    linux-lts \
    busybox-static \
    kmod \
    tzdata \
    ca-certificates

# Firmware subpackages — try each individually so the build doesn't fail
# when Alpine renames or drops a subpackage (e.g. myri10ge removed in 3.21).
for fw in \
    linux-firmware-bnx2 \
    linux-firmware-bnx2x \
    linux-firmware-cxgb3 \
    linux-firmware-cxgb4 \
    linux-firmware-intel \
    linux-firmware-mellanox \
    linux-firmware-netronome \
    linux-firmware-other \
    linux-firmware-qed \
    linux-firmware-qlogic \
    linux-firmware-tigon
do
    apk add --no-cache "$fw" 2>/dev/null \
        || echo "verity: skipping unavailable firmware package: $fw"
done

adduser -D -H -s /sbin/nologin nginx 2>/dev/null || true
mkdir -p /var/www/html /var/log/nginx /run/nginx
chown -R nginx:nginx /var/www/html /var/log/nginx /run/nginx
CHROOT_EOF

# --- Build initramfs ---
# Must happen BEFORE harden_system removes /boot, /lib/modules, /lib/firmware.

log "Building initramfs"

VMLINUZ=$(ls "$WORK_DIR/rootfs/boot"/vmlinuz-lts 2>/dev/null) \
    || error "vmlinuz-lts not found — linux-lts failed to install"
cp "$VMLINUZ" "$WORK_DIR/iso/boot/vmlinuz"

cp "$WORK_DIR/rootfs/bin/busybox.static" "$WORK_DIR/initramfs/bin/busybox"

INITRAMFS="$WORK_DIR/initramfs"
# Applets needed by initramfs-init.
for applet in sh mount umount mkdir sleep ls cat grep awk sed cut tr \
              basename dirname \
              modprobe losetup switch_root ip udhcpc wget; do
    ln -sf busybox "$INITRAMFS/bin/$applet"
done

# udhcpc needs a default script.
mkdir -p "$INITRAMFS/usr/share/udhcpc"
cp "$WORK_DIR/rootfs/usr/share/udhcpc/default.script" \
   "$INITRAMFS/usr/share/udhcpc/default.script" 2>/dev/null || \
cat > "$INITRAMFS/usr/share/udhcpc/default.script" <<'SCRIPT'
#!/bin/sh
[ -n "$1" ] || exit 1
case "$1" in
    bound|renew)
        /bin/busybox ip addr flush dev "$interface"
        /bin/busybox ip addr add "$ip/${mask:-24}" dev "$interface"
        [ -n "$router" ] && /bin/busybox ip route add default via "$router" dev "$interface" 2>/dev/null
        : > /etc/resolv.conf
        for ns in $dns; do echo "nameserver $ns" >> /etc/resolv.conf; done
        ;;
esac
SCRIPT
chmod +x "$INITRAMFS/usr/share/udhcpc/default.script"

# Modules to load in initramfs.
# Storage: NVMe, AHCI/SATA, USB, HW RAID, virtio, MMC.
# Net: Intel, Broadcom, Mellanox, Realtek, Aquantia, QLogic.
# FS / block: squashfs, loop, isofs, overlay, dm-mod.
MODULES="
    squashfs loop isofs overlay dm-mod cdrom sr_mod
    sd_mod nvme nvme_core ahci libahci
    usb_storage uas xhci_hcd xhci_pci ehci_hcd ehci_pci ohci_hcd ohci_pci
    mmc_block sdhci sdhci_pci
    megaraid_sas mpt3sas mptsas hpsa aacraid
    virtio_blk virtio_pci virtio_scsi virtio_net virtio_ring virtio
    e1000 e1000e igb igc ixgbe ixgbevf i40e ice
    bnx2 bnx2x bnxt_en tg3 r8169 atlantic qede
    mlx4_core mlx4_en mlx5_core
    af_packet unix
"

KVER=$(ls "$WORK_DIR/rootfs/lib/modules/" | head -1)
[ -n "$KVER" ] || error "No kernel modules found"
ROOTMOD="$WORK_DIR/rootfs/lib/modules/$KVER"
MODDIR="$INITRAMFS/lib/modules/$KVER"
mkdir -p "$MODDIR"

# Resolve full dependency chains using modprobe inside the rootfs chroot.
# `modprobe -D` prints insmod lines for module + deps; we extract .ko paths.
log "Resolving module dependencies"
RESOLVED_LIST="$WORK_DIR/modules.list"
: > "$RESOLVED_LIST"
for mod in $MODULES; do
    chroot "$WORK_DIR/rootfs" modprobe -D "$mod" 2>/dev/null \
        | awk '/^insmod/ {print $2}' >> "$RESOLVED_LIST" || true
done
sort -u "$RESOLVED_LIST" -o "$RESOLVED_LIST"

# Copy each resolved .ko, preserving the modules.dep-relative path.
while IFS= read -r modpath; do
    [ -z "$modpath" ] && continue
    # Path is absolute from chroot perspective: /lib/modules/$KVER/...
    src="$WORK_DIR/rootfs$modpath"
    [ -f "$src" ] || continue
    rel="${modpath#/lib/modules/$KVER/}"
    dst="$MODDIR/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
done < "$RESOLVED_LIST"

# Copy module metadata; depmod regenerates dep info against our subset.
for f in modules.builtin modules.builtin.modinfo modules.order; do
    [ -f "$ROOTMOD/$f" ] && cp "$ROOTMOD/$f" "$MODDIR/" || true
done
depmod -b "$INITRAMFS" "$KVER"

# Copy firmware blobs for the NIC families above. Drivers will look in
# /lib/firmware/* during initramfs network bring-up (PXE path).
log "Bundling firmware in initramfs"
if [ -d "$WORK_DIR/rootfs/lib/firmware" ]; then
    cp -a "$WORK_DIR/rootfs/lib/firmware/." "$INITRAMFS/lib/firmware/"
fi

# Our init script.
cp "$PROJECT_DIR/scripts/initramfs-init" "$INITRAMFS/init"
chmod +x "$INITRAMFS/init"

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

if [ -d "$PROJECT_DIR/www" ] && ls "$PROJECT_DIR/www/"* >/dev/null 2>&1; then
    cp -r "$PROJECT_DIR/www/"* "$WORK_DIR/rootfs/var/www/html/"
fi
chroot "$WORK_DIR/rootfs" chown -R nginx:nginx /var/www/html

# --- Harden ---
# Keep /lib/firmware in the squashfs so drivers loaded post-switch_root
# (e.g. on hotplug or reset) can still find their blobs.

log "Hardening system"
chroot "$WORK_DIR/rootfs" /bin/sh <<'CHROOT_EOF'
set -e

# Package manager — gone.
rm -f /sbin/apk /usr/bin/apk

# Kernel + modules already extracted into initramfs.
rm -rf /boot /lib/modules

# Build-time helpers no longer needed at runtime.
rm -f /sbin/depmod /sbin/modprobe /sbin/modinfo /sbin/insmod /sbin/rmmod /sbin/lsmod
rm -f /usr/bin/wget /usr/bin/curl /usr/bin/vi /usr/bin/nano
rm -f /usr/bin/strace /usr/bin/gdb

rm -rf /usr/share/man /usr/share/doc
rm -rf /var/cache/apk/* /tmp/*
CHROOT_EOF

# --- Unmount chroot ---

log "Unmounting chroot"
umount "$WORK_DIR/rootfs/proc"
umount "$WORK_DIR/rootfs/sys"
umount "$WORK_DIR/rootfs/dev"
trap - EXIT

# --- Create squashfs ---

log "Creating squashfs"
mksquashfs "$WORK_DIR/rootfs" "$WORK_DIR/iso/rootfs.squashfs" \
    -comp xz -noappend -quiet
[ -f "$WORK_DIR/iso/rootfs.squashfs" ] || error "squashfs creation failed"

# --- BIOS bootloader (ISOLINUX) ---

log "Setting up ISOLINUX (BIOS)"

KCMD="console=ttyS0,115200n8 console=tty0 quiet"

cat > "$WORK_DIR/iso/boot/isolinux/isolinux.cfg" <<EOF
SERIAL 0 115200
DEFAULT verity
PROMPT 0
TIMEOUT 1
LABEL verity
    LINUX /boot/vmlinuz
    INITRD /boot/initramfs.gz
    APPEND $KCMD
EOF

ISOLINUX_BIN=""
for path in \
    /usr/lib/syslinux/bios/isolinux.bin \
    /usr/lib/ISOLINUX/isolinux.bin \
    /usr/share/syslinux/isolinux.bin; do
    [ -f "$path" ] && { ISOLINUX_BIN="$path"; break; }
done
[ -n "$ISOLINUX_BIN" ] || error "isolinux.bin not found — install syslinux"
cp "$ISOLINUX_BIN" "$WORK_DIR/iso/boot/isolinux/"

for path in \
    /usr/lib/syslinux/bios/ldlinux.c32 \
    /usr/lib/syslinux/modules/bios/ldlinux.c32 \
    /usr/share/syslinux/ldlinux.c32; do
    [ -f "$path" ] && { cp "$path" "$WORK_DIR/iso/boot/isolinux/"; break; }
done

ISOHDPFX=""
for path in \
    /usr/share/syslinux/isohdpfx.bin \
    /usr/lib/syslinux/bios/isohdpfx.bin \
    /usr/lib/ISOLINUX/isohdpfx.bin; do
    [ -f "$path" ] && { ISOHDPFX="$path"; break; }
done
[ -n "$ISOHDPFX" ] || error "isohdpfx.bin not found — install syslinux"

# --- UEFI bootloader (GRUB EFI) ---

log "Building UEFI loader (GRUB)"

GRUB_CFG="$WORK_DIR/grub-embed.cfg"
cat > "$GRUB_CFG" <<EOF
set timeout=1
set default=0
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial
insmod part_gpt
insmod part_msdos
insmod iso9660
insmod fat
search --no-floppy --set=root --label VERITY
menuentry "Verity" {
    linux /boot/vmlinuz $KCMD
    initrd /boot/initramfs.gz
}
EOF

mkdir -p "$WORK_DIR/efi/EFI/BOOT"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="$WORK_DIR/efi/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt part_msdos iso9660 fat normal linux configfile search search_label echo serial terminal" \
    --locales="" --fonts="" --themes="" \
    "boot/grub/grub.cfg=$GRUB_CFG"

# Pack BOOTX64.EFI into a FAT image El Torito can boot.
EFI_IMG="$WORK_DIR/iso/boot/efiboot.img"
EFI_SIZE_KB=$(( ($(stat -c%s "$WORK_DIR/efi/EFI/BOOT/BOOTX64.EFI") / 1024) + 2048 ))
dd if=/dev/zero of="$EFI_IMG" bs=1024 count="$EFI_SIZE_KB" status=none
mkfs.vfat -n EFIBOOT "$EFI_IMG" >/dev/null
mmd -i "$EFI_IMG" ::/EFI
mmd -i "$EFI_IMG" ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$WORK_DIR/efi/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/

# --- Create ISO (hybrid BIOS + UEFI, USB-bootable) ---

log "Creating hybrid ISO"
xorriso -as mkisofs \
    -o "$OUTPUT_DIR/$ISO_NAME" \
    -V "VERITY" \
    -isohybrid-mbr "$ISOHDPFX" \
    -c boot/isolinux/boot.cat \
    -b boot/isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    "$WORK_DIR/iso/"

[ -f "$OUTPUT_DIR/$ISO_NAME" ] || error "ISO creation failed"

# --- PXE artifacts ---

log "Publishing PXE artifacts"
cp "$WORK_DIR/iso/boot/vmlinuz"      "$PXE_DIR/vmlinuz"
cp "$WORK_DIR/iso/boot/initramfs.gz" "$PXE_DIR/initramfs.gz"
cp "$WORK_DIR/iso/rootfs.squashfs"   "$PXE_DIR/rootfs.squashfs"

# --- Summary ---

log "Build complete!"
echo ""
echo "  ISO:  $OUTPUT_DIR/$ISO_NAME ($(du -h "$OUTPUT_DIR/$ISO_NAME" | cut -f1))"
echo "  PXE:  $PXE_DIR/{vmlinuz,initramfs.gz,rootfs.squashfs}"
echo ""
echo "  Boot:  BIOS + UEFI, CD/USB/IPMI virtual media, PXE"
echo "  Test:  make test       (BIOS)"
echo "         make test-uefi  (UEFI, needs OVMF)"
echo ""
echo "  PXE cmdline example:"
echo "    console=ttyS0,115200n8 console=tty0 verity.rootfs=http://host/rootfs.squashfs"
echo ""
