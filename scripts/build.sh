#!/bin/bash
set -euo pipefail

# Verity Build Script
# Creates a minimal, locked-down Alpine Linux ISO.
# Sources verity.conf for optional components (mDNS, Node.js, PostgreSQL).

ALPINE_VERSION="3.21"
ALPINE_RELEASE="${ALPINE_VERSION}.0"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="/tmp/verity-build"
OUTPUT_DIR="$PROJECT_DIR/build"
ISO_NAME="verity.iso"

# Source optional component config
[ -f "$PROJECT_DIR/verity.conf" ] && . "$PROJECT_DIR/verity.conf"
ENABLE_MDNS="${ENABLE_MDNS:-no}"
ENABLE_NODE="${ENABLE_NODE:-no}"
ENABLE_POSTGRES="${ENABLE_POSTGRES:-no}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()   { echo -e "${GREEN}[verity]${NC} $1"; }
error() { echo -e "${RED}[verity]${NC} $1" >&2; exit 1; }

log "Configuration: mDNS=$ENABLE_MDNS Node=$ENABLE_NODE Postgres=$ENABLE_POSTGRES"

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

# --- Build conditional package list ---

EXTRA_PACKAGES=""
[ "$ENABLE_MDNS" = "yes" ]     && EXTRA_PACKAGES="$EXTRA_PACKAGES avahi" || true
[ "$ENABLE_NODE" = "yes" ]     && EXTRA_PACKAGES="$EXTRA_PACKAGES nodejs npm" || true
[ "$ENABLE_POSTGRES" = "yes" ] && EXTRA_PACKAGES="$EXTRA_PACKAGES postgresql" || true

# --- Install packages ---

log "Installing packages"
chroot "$WORK_DIR/rootfs" /bin/sh <<CHROOT_EOF
set -e
apk update
apk add --no-cache \
    nginx \
    linux-lts \
    busybox-static \
    tzdata \
    ca-certificates \
    $EXTRA_PACKAGES
adduser -D -H -s /sbin/nologin nginx 2>/dev/null || true
mkdir -p /var/www/html /var/log/nginx /run/nginx
chown -R nginx:nginx /var/www/html /var/log/nginx /run/nginx
CHROOT_EOF

# --- Install Node.js app ---

if [ "$ENABLE_NODE" = "yes" ]; then
    log "Installing Node.js application"
    mkdir -p "$WORK_DIR/rootfs/opt/app"
    cp "$PROJECT_DIR/app/server.js"   "$WORK_DIR/rootfs/opt/app/"
    cp "$PROJECT_DIR/app/package.json" "$WORK_DIR/rootfs/opt/app/"
    [ -f "$PROJECT_DIR/app/seed.sql" ] && cp "$PROJECT_DIR/app/seed.sql" "$WORK_DIR/rootfs/opt/app/"

    chroot "$WORK_DIR/rootfs" /bin/sh <<'CHROOT_EOF'
set -e
cd /opt/app
npm install --production 2>/dev/null
rm -rf /root/.npm /tmp/.npm
CHROOT_EOF
fi

# --- Copy avahi config ---

if [ "$ENABLE_MDNS" = "yes" ]; then
    log "Configuring avahi"
    mkdir -p "$WORK_DIR/rootfs/etc/avahi"
    cp "$PROJECT_DIR/config/avahi-daemon.conf" "$WORK_DIR/rootfs/etc/avahi/avahi-daemon.conf"
fi

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
cp "$PROJECT_DIR/config/sysctl.conf" "$WORK_DIR/rootfs/etc/sysctl.conf"

# Select nginx config based on whether Node.js is enabled
if [ "$ENABLE_NODE" = "yes" ]; then
    cp "$PROJECT_DIR/config/nginx-proxy.conf" "$WORK_DIR/rootfs/etc/nginx/nginx.conf"
else
    cp "$PROJECT_DIR/config/nginx.conf" "$WORK_DIR/rootfs/etc/nginx/nginx.conf"
fi

# --- Generate init script ---

log "Generating init script"
cat > "$WORK_DIR/rootfs/sbin/init" <<'INIT_HEADER'
#!/bin/sh

# Verity — PID 1 init (generated by build.sh)

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Writable tmpfs mounts
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /tmp
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /var/log
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run
mkdir -p /var/log/nginx /run/nginx

# Remount root as read-only
mount -o remount,ro /

# Networking
ip link set lo up
ip link set eth0 up 2>/dev/null
udhcpc -i eth0 -s /usr/share/udhcpc/default.script -b -q 2>/dev/null

# Apply sysctl hardening
sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
INIT_HEADER

# Avahi section
if [ "$ENABLE_MDNS" = "yes" ]; then
    cat >> "$WORK_DIR/rootfs/sbin/init" <<'INIT_AVAHI'

# Start mDNS discovery
echo "verity: starting avahi"
avahi-daemon --daemonize --no-chroot 2>/dev/null
INIT_AVAHI
fi

# PostgreSQL section
if [ "$ENABLE_POSTGRES" = "yes" ]; then
    cat >> "$WORK_DIR/rootfs/sbin/init" <<'INIT_POSTGRES'

# Start PostgreSQL (ephemeral — data lives on tmpfs, lost on reboot)
echo "verity: starting postgresql"
adduser -D -H -s /sbin/nologin postgres 2>/dev/null || true
mkdir -p /tmp/pgdata /run/postgresql
chown postgres:postgres /tmp/pgdata /run/postgresql

su -s /bin/sh postgres -c "initdb -D /tmp/pgdata --no-locale --auth=trust" >/dev/null 2>&1

# Configure PostgreSQL
cat > /tmp/pgdata/postgresql.conf <<PGCONF
listen_addresses = '127.0.0.1'
port = 5432
max_connections = 20
shared_buffers = 32MB
unix_socket_directories = '/run/postgresql'
logging_collector = off
log_destination = 'stderr'
PGCONF

cat > /tmp/pgdata/pg_hba.conf <<PGHBA
local   all   all                 trust
host    all   all   127.0.0.1/32  trust
PGHBA

su -s /bin/sh postgres -c "pg_ctl start -D /tmp/pgdata -l /var/log/postgresql.log" 2>/dev/null

# Wait for PostgreSQL to be ready
tries=0
while [ $tries -lt 15 ]; do
    if su -s /bin/sh postgres -c "pg_isready -h 127.0.0.1" >/dev/null 2>&1; then
        break
    fi
    sleep 1
    tries=$((tries + 1))
done

# Create database and run seed
su -s /bin/sh postgres -c "createdb verity" 2>/dev/null || true
if [ -f /opt/app/seed.sql ]; then
    su -s /bin/sh postgres -c "psql -h 127.0.0.1 -d verity -f /opt/app/seed.sql" >/dev/null 2>&1 || true
fi
INIT_POSTGRES
fi

# Node.js section
if [ "$ENABLE_NODE" = "yes" ]; then
    cat >> "$WORK_DIR/rootfs/sbin/init" <<'INIT_NODE'

# Start Node.js API
echo "verity: starting node api"
node /opt/app/server.js &
INIT_NODE
fi

# nginx section (always)
cat >> "$WORK_DIR/rootfs/sbin/init" <<'INIT_NGINX'

echo "verity: starting nginx"

# Exec replaces this process — nginx becomes PID 1
exec nginx -g "daemon off;"
INIT_NGINX

chmod +x "$WORK_DIR/rootfs/sbin/init"

# Copy web content
if [ -d "$PROJECT_DIR/www" ] && ls "$PROJECT_DIR/www/"* >/dev/null 2>&1; then
    cp -r "$PROJECT_DIR/www/"* "$WORK_DIR/rootfs/var/www/html/"
fi
chroot "$WORK_DIR/rootfs" chown -R nginx:nginx /var/www/html

# --- Harden ---

log "Hardening system"
chroot "$WORK_DIR/rootfs" /bin/sh <<CHROOT_EOF
set -e

# Remove package manager
rm -f /sbin/apk /usr/bin/apk

# Remove kernel source + modules (already extracted to initramfs)
rm -rf /boot /lib/modules

# Remove unnecessary tools
rm -f /usr/bin/wget /usr/bin/curl /usr/bin/vi /usr/bin/nano
rm -f /usr/bin/strace /usr/bin/gdb

# Remove npm at runtime (keep node binary)
$([ "$ENABLE_NODE" = "yes" ] && echo "rm -f /usr/bin/npm /usr/bin/npx" || true)
$([ "$ENABLE_NODE" = "yes" ] && echo "rm -rf /usr/lib/node_modules" || true)

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
echo "  Components: nginx$([ "$ENABLE_MDNS" = "yes" ] && echo ", avahi")$([ "$ENABLE_NODE" = "yes" ] && echo ", node")$([ "$ENABLE_POSTGRES" = "yes" ] && echo ", postgresql")"
echo ""
echo "  Test: make test"
echo ""
