#!/bin/bash
set -euo pipefail

# Verity — QEMU test helper
# Boots the ISO with port forwarding so you can curl localhost:8080

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISO="$PROJECT_DIR/build/verity.iso"

if [ ! -f "$ISO" ]; then
    echo "ISO not found at $ISO — run 'make build' first"
    exit 1
fi

command -v qemu-system-x86_64 >/dev/null || {
    echo "qemu-system-x86_64 not found — install QEMU"
    exit 1
}

echo "Booting verity ISO..."
echo "  http://localhost:8080 will be available once nginx starts"
echo "  Press Ctrl+C to stop"
echo ""

qemu-system-x86_64 \
    -cdrom "$ISO" \
    -m 512 \
    -nographic \
    -serial mon:stdio \
    -net nic,model=e1000 \
    -net user,hostfwd=tcp::8080-:80
