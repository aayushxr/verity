#!/bin/bash
set -euo pipefail

# Verity — QEMU test helper
# Boots the ISO with port forwarding so you can curl localhost:8080

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISO="$PROJECT_DIR/build/verity.iso"

# Source config for dynamic RAM sizing
[ -f "$PROJECT_DIR/verity.conf" ] && . "$PROJECT_DIR/verity.conf"
ENABLE_POSTGRES="${ENABLE_POSTGRES:-no}"

if [ ! -f "$ISO" ]; then
    echo "ISO not found at $ISO — run 'make build' first"
    exit 1
fi

command -v qemu-system-x86_64 >/dev/null || {
    echo "qemu-system-x86_64 not found — install QEMU"
    exit 1
}

# PostgreSQL needs more RAM for shared_buffers + initdb
if [ "$ENABLE_POSTGRES" = "yes" ]; then
    RAM=1024
else
    RAM=512
fi

echo "Booting verity ISO..."
echo "  http://localhost:8080 will be available once nginx starts"
echo "  RAM: ${RAM}MB"
echo "  Press Ctrl+C to stop"
echo ""

qemu-system-x86_64 \
    -cdrom "$ISO" \
    -m "$RAM" \
    -nographic \
    -serial mon:stdio \
    -net nic,model=e1000 \
    -net user,hostfwd=tcp::8080-:80
