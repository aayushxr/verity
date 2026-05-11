#!/bin/bash
set -euo pipefail

# Verity — QEMU test helper
# Boots the ISO with port forwarding so you can curl localhost:8080.
# Pass UEFI=1 to boot via OVMF firmware instead of legacy BIOS.

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

QEMU_ARGS=(
    -cdrom "$ISO"
    -m 512
    -nographic
    -serial mon:stdio
    -net nic,model=e1000
    -net user,hostfwd=tcp::8080-:80
)

if [ "${UEFI:-0}" = "1" ]; then
    OVMF=""
    for path in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
        /usr/local/share/qemu/edk2-x86_64-code.fd; do
        [ -f "$path" ] && { OVMF="$path"; break; }
    done
    [ -n "$OVMF" ] || { echo "OVMF firmware not found — install ovmf / edk2"; exit 1; }
    echo "Booting verity ISO (UEFI / OVMF)..."
    QEMU_ARGS+=( -bios "$OVMF" )
else
    echo "Booting verity ISO (BIOS)..."
fi

echo "  http://localhost:8080 once nginx starts"
echo "  Ctrl+A then X to quit"
echo ""

qemu-system-x86_64 "${QEMU_ARGS[@]}"
