# verity

A minimal, hardened Alpine Linux ISO that boots directly into nginx. No shell, no package manager, no SSH — just a static file server on a read-only root filesystem.

## Quick start

```
make build    # builds the ISO (uses Docker on macOS)
make test     # boots in QEMU with port 8080 forwarded
curl http://localhost:8080
```

## What it does

Verity builds a bootable ISO (~50-100 MB) that:

- Boots via ISOLINUX into a custom initramfs
- Mounts a squashfs root filesystem (read-only)
- Brings up networking via DHCP
- Applies kernel hardening (sysctl)
- Runs nginx as PID 1 — nothing else

## Boot chain

```
BIOS → ISOLINUX → vmlinuz + initramfs
  → initramfs-init loads modules (squashfs, loop, isofs, sr_mod, virtio)
  → scans block devices for rootfs.squashfs
  → mounts squashfs read-only → switch_root
  → /sbin/init brings up networking, applies sysctl
  → exec nginx (becomes PID 1)
```

## Project layout

```
scripts/
  build.sh          # main build script (run as root or via Docker)
  initramfs-init    # initramfs /init — finds and mounts the squashfs
  test.sh           # QEMU test helper
config/
  init              # PID 1 init for the real root
  nginx.conf        # nginx config with security headers
  sysctl.conf       # kernel hardening parameters
www/
  index.html        # default landing page
Makefile            # build orchestration
```

## Build requirements

**Linux (native):** `bash`, `wget`, `xorriso`, `squashfs-tools`, `cpio`, `syslinux`, root access

**macOS:** Docker (the Makefile runs the build inside `alpine:3.21`)

**Testing:** `qemu-system-x86_64`

## Customization

Replace `www/index.html` (or add files to `www/`) with your static site content. Edit `config/nginx.conf` to adjust the server configuration.

## Security

- Read-only squashfs root
- No shell access, no package manager, no SSH
- Kernel hardening via sysctl (ASLR, kptr_restrict, module loading disabled post-boot)
- nginx security headers: CSP, X-Frame-Options DENY, X-Content-Type-Options, Permissions-Policy
- Rate limiting (10 req/s per IP)
- Server version hidden

## License

MIT
