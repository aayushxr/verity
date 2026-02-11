#!/bin/sh

# Verity — Interactive configuration
# Prompts for optional components and writes verity.conf

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="$PROJECT_DIR/verity.conf"

ask() {
    printf "%s [y/N] " "$1"
    read -r answer
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

echo ""
echo "  Verity — Configure Components"
echo "  =============================="
echo ""

ENABLE_MDNS=no
ENABLE_NODE=no
ENABLE_POSTGRES=no

if ask "Include mDNS discovery (avahi)?"; then
    ENABLE_MDNS=yes
fi

if ask "Include Node.js runtime?"; then
    ENABLE_NODE=yes
    if ask "Include PostgreSQL database?"; then
        ENABLE_POSTGRES=yes
    fi
fi

cat > "$CONF" <<EOF
ENABLE_MDNS=$ENABLE_MDNS
ENABLE_NODE=$ENABLE_NODE
ENABLE_POSTGRES=$ENABLE_POSTGRES
EOF

echo ""
echo "  Configuration saved to verity.conf:"
echo "    mDNS:       $ENABLE_MDNS"
echo "    Node.js:    $ENABLE_NODE"
echo "    PostgreSQL: $ENABLE_POSTGRES"
echo ""
echo "  Run 'make build' to create the ISO."
echo ""
