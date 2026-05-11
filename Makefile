.PHONY: build test test-uefi clean

ISO := build/verity.iso

# Build-time deps installed inside the Alpine container on macOS:
#   bash wget         download + scripting
#   xorriso           hybrid ISO assembly
#   squashfs-tools    read-only root image
#   cpio gzip         initramfs packaging
#   syslinux          BIOS bootloader (ISOLINUX + isohdpfx)
#   grub-efi          UEFI bootloader (grub-mkstandalone)
#   mtools dosfstools FAT image for the EFI El Torito entry
#   kmod              depmod for module-dependency resolution
DOCKER_DEPS := bash wget xorriso squashfs-tools cpio syslinux grub-efi mtools dosfstools kmod

build:
ifeq ($(shell uname), Darwin)
	@echo "macOS detected — building inside Docker"
	docker run --rm --privileged \
		--platform linux/amd64 \
		-v "$(CURDIR)":/verity \
		-w /verity \
		alpine:3.21 \
		sh -c "apk add --no-cache $(DOCKER_DEPS) && bash scripts/build.sh"
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
