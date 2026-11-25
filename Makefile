# Convenience wrapper around the Containerfile.

IMAGE_NAME ?= localhost/fedora-bootc-noctalia-sealed-image
IMAGE ?= $(IMAGE_NAME):latest
NVIDIA_IMAGE ?= $(IMAGE_NAME)-nvidia-open:latest
BASE_IMAGE ?= quay.io/fedora/fedora-bootc:45
FEDORA_RELEASE ?= 45
SIGN_UKI ?= 0
INSTALL_GITHUB_RUNNER ?= 1
INSTALL_NVIDIA_OPEN ?= 0
VCONSOLE_KEYMAP ?= us
KEYS ?= keys
PODMAN ?= podman

.PHONY: all build build-signed build-unsigned build-nvidia build-nvidia-signed \
	build-nvidia-unsigned keys certs shellcheck

all: build

# Build an unsigned UKI when no keys are present. Secure Boot will not trust
# this image, but the composefs digest is still embedded and verified.
build:
	@mkdir -p "$(KEYS)"
	@if [ "$(SIGN_UKI)" = "1" ]; then \
		test -s "$(KEYS)/secureboot.key" && test -s "$(KEYS)/secureboot.crt" || \
		{ echo "Missing $(KEYS)/secureboot.key or $(KEYS)/secureboot.crt; run 'make keys'." >&2; exit 1; }; \
		secret_dir="$(abspath $(KEYS))"; \
	else \
		secret_dir="$(abspath $(KEYS))/.unsigned"; \
		mkdir -p "$$secret_dir"; \
		: >"$$secret_dir/secureboot.key"; \
		: >"$$secret_dir/secureboot.crt"; \
	fi; \
	cache_bust=$$(sha256sum "$$secret_dir/secureboot.crt" | cut -d' ' -f1); \
	$(PODMAN) build \
		--layers \
		--skip-unused-stages=false \
		--security-opt=label=disable \
		-v "$(CURDIR):/run/src" \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg FEDORA_RELEASE="$(FEDORA_RELEASE)" \
		--build-arg SIGN_UKI="$(SIGN_UKI)" \
		--build-arg UKI_CACHE_BUST="$$cache_bust" \
		--build-arg INSTALL_GITHUB_RUNNER="$(INSTALL_GITHUB_RUNNER)" \
		--build-arg INSTALL_NVIDIA_OPEN="$(INSTALL_NVIDIA_OPEN)" \
		--build-arg VCONSOLE_KEYMAP="$(VCONSOLE_KEYMAP)" \
		--secret id=secureboot_key,src="$$secret_dir/secureboot.key" \
		--secret id=secureboot_cert,src="$$secret_dir/secureboot.crt" \
		--label org.opencontainers.image.title="Fedora bootc Noctalia Sealed" \
		--tag "$(IMAGE)" \
		.

build-signed: keys
	$(MAKE) build SIGN_UKI=1

build-unsigned:
	$(MAKE) build SIGN_UKI=0

# NVIDIA variant: RPM Fusion's akmod-nvidia built as the open kernel module.
build-nvidia:
	$(MAKE) build INSTALL_NVIDIA_OPEN=1 IMAGE="$(NVIDIA_IMAGE)"

build-nvidia-signed: keys
	$(MAKE) build INSTALL_NVIDIA_OPEN=1 SIGN_UKI=1 IMAGE="$(NVIDIA_IMAGE)"

build-nvidia-unsigned:
	$(MAKE) build INSTALL_NVIDIA_OPEN=1 SIGN_UKI=0 IMAGE="$(NVIDIA_IMAGE)"

keys:
	@test -s "$(KEYS)/secureboot.key" && test -s "$(KEYS)/secureboot.crt" || \
		./scripts/generate-secureboot-keys.sh "$(KEYS)"

# Publish the public certificate: copy it from KEYS into certs/ and refresh
# SHA256SUMS. Run this after rotating keys, then commit certs/.
certs:
	@test -s "$(KEYS)/secureboot.crt" && test -s "$(KEYS)/secureboot.cer" || \
		{ echo "Missing $(KEYS)/secureboot.crt or $(KEYS)/secureboot.cer; run 'make keys'." >&2; exit 1; }
	install -m 0644 "$(KEYS)/secureboot.crt" certs/secureboot.crt
	install -m 0644 "$(KEYS)/secureboot.cer" certs/secureboot.cer
	cd certs && sha256sum secureboot.crt secureboot.cer > SHA256SUMS
	@openssl x509 -in certs/secureboot.crt -noout -subject -fingerprint -sha256 -dates

shellcheck:
	shellcheck scripts/*.sh rootfs/usr/libexec/initial-firstboot \
		rootfs/usr/libexec/github-runner-setup \
		rootfs/usr/libexec/sync-shim-systemd-boot
