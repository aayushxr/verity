# verity

A sovereign, hardened Alpine Linux ISO that boots directly into nginx. No shell, no package manager, no SSH — just a static file server on a read-only root filesystem.

## What is sovereignty?

Most servers are held together by trust in things you don't control — upstream repos, package managers, update daemons, shell access that "probably nobody will use." Every one of those is an assumption, and every assumption is a surface.

Sovereignty means your server runs exactly what you built, nothing more. Verity achieves this by eliminating every component that isn't strictly necessary to serve files:

- **No package manager.** apk is deleted after build. Nothing can be installed at runtime.
- **No shell.** There is no way to get an interactive session. No SSH, no TTY, no login.
- **No mutation.** The root filesystem is squashfs — read-only by nature, not by policy. There is no `remount,rw`.
- **No ambient authority.** Kernel module loading is disabled after boot. ptrace is restricted. kexec is off.
- **No opinions you didn't choose.** The entire system is ~400 lines of shell across a handful of files. You can read all of it in one sitting.

The result is a machine that does one thing, can't be told to do anything else, and can be fully understood by one person.

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
