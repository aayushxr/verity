.PHONY: build test clean

ISO := build/verity.iso

build:
ifeq ($(shell uname), Darwin)
	@echo "macOS detected — building inside Docker"
	docker run --rm --privileged \
		--platform linux/amd64 \
		-v "$(CURDIR)":/verity \
		-w /verity \
		alpine:3.21 \
		sh -c "apk add --no-cache bash wget xorriso squashfs-tools cpio syslinux && bash scripts/build.sh"
else
	sudo bash scripts/build.sh
endif

test: $(ISO)
	bash scripts/test.sh

$(ISO):
	$(MAKE) build

clean:
	rm -rf build/

