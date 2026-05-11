.PHONY: build test test-uefi clean

ISO := build/verity.iso

# build.sh auto-installs its own deps (xorriso, squashfs-tools, syslinux,
# grub-efi, mtools, dosfstools, kmod, cpio, wget) on apk/apt/dnf/yum systems.
# On macOS the Alpine container needs `bash` first because the script is
# `#!/bin/bash` and uses bash-isms.

build:
ifeq ($(shell uname), Darwin)
	@echo "macOS detected — building inside Docker"
	docker run --rm --privileged \
		--platform linux/amd64 \
		-v "$(CURDIR)":/verity \
		-w /verity \
		alpine:3.21 \
		sh -c "apk add --no-cache bash && bash scripts/build.sh"
else
	sudo bash scripts/build.sh
endif

test: $(ISO)
	bash scripts/test.sh

test-uefi: $(ISO)
	UEFI=1 bash scripts/test.sh

$(ISO):
	$(MAKE) build

clean:
	rm -rf build/
