# Convenience wrapper around the Containerfile.

IMAGE ?= localhost/fedora-bootc-noctalia-sealed:latest
BASE_IMAGE ?= quay.io/fedora/fedora-bootc:45
FEDORA_RELEASE ?= 45
SIGN_UKI ?= 0
INSTALL_GITHUB_RUNNER ?= 1
VCONSOLE_KEYMAP ?= us
KEYS ?= keys
PODMAN ?= podman

.PHONY: all build build-signed build-unsigned keys shellcheck

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

keys:
	@test -s "$(KEYS)/secureboot.key" && test -s "$(KEYS)/secureboot.crt" || \
		./scripts/generate-secureboot-keys.sh "$(KEYS)"

shellcheck:
	shellcheck scripts/*.sh rootfs/usr/libexec/initial-firstboot \
		rootfs/usr/libexec/github-runner-setup \
		rootfs/usr/libexec/sync-shim-systemd-boot
