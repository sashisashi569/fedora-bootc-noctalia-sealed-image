# Fedora bootc "sealed" image with the Noctalia family desktop.
#
# Boot chain:
#   UEFI firmware -> shim -> systemd-boot -> signed UKI -> systemd
#
# The final image is a composefs/sealed image:
#   * the kernel and initramfs are embedded in a UKI under /boot/EFI/Linux
#   * the UKI contains the composefs digest of the (split) root filesystem
#   * the UKI is signed with the key supplied as BuildKit secrets
#
# BuildKit secrets (always required by this Containerfile; pass empty files
# when SIGN_UKI=0):
#   --secret id=secureboot_key,src=secureboot.key
#   --secret id=secureboot_cert,src=secureboot.crt
#
# UKI_CACHE_BUST must change whenever the signing key changes: BuildKit does
# not include secret contents in the layer cache key. The Makefile and CI set
# it to the SHA256 of the certificate.
#
# Example (chunkah's FROM oci:out flow requires Podman/Buildah):
#   podman build \
#     --skip-unused-stages=false --security-opt=label=disable \
#     -v "$PWD:/run/src" \
#     --build-arg SIGN_UKI=1 \
#     --build-arg INSTALL_NVIDIA_OPEN=0 \
#     --build-arg UKI_CACHE_BUST="$(sha256sum keys/secureboot.crt | cut -d' ' -f1)" \
#     --secret id=secureboot_key,src=keys/secureboot.key \
#     --secret id=secureboot_cert,src=keys/secureboot.crt \
#     -t localhost/fedora-bootc-noctalia-sealed .
#
# INSTALL_NVIDIA_OPEN=1 adds RPM Fusion's NVIDIA open kernel module (built with
# akmod-nvidia) and the matching user-space driver. The module is signed with
# the same key as the UKI.

ARG BASE_IMAGE=quay.io/fedora/fedora-bootc:45
ARG TOOLS_IMAGE=registry.fedoraproject.org/fedora:45
ARG FEDORA_RELEASE=45
ARG INSTALL_GITHUB_RUNNER=1
ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
ARG SIGN_UKI=0
ARG INSTALL_NVIDIA_OPEN=0
ARG VCONSOLE_KEYMAP=us

# The build helper scripts are only mounted into the build; they are not
# copied into the final image. Host-side helpers (key generation, installation)
# are intentionally not part of this stage so changing them does not invalidate
# the container build cache.
FROM scratch AS scripts
COPY --chmod=0755 scripts/install-packages.sh /
COPY --chmod=0755 scripts/install-nvidia-open.sh /
COPY --chmod=0755 scripts/configure-system.sh /
COPY --chmod=0755 scripts/install-github-runner.sh /
COPY --chmod=0755 scripts/rebuild-initramfs.sh /
COPY --chmod=0755 scripts/split-kernel.sh /
COPY --chmod=0755 scripts/build-uki.sh /
COPY --chmod=0755 scripts/sign-systemd-boot.sh /

# ---------------------------------------------------------------------------
# 1. Root filesystem
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS rootfs

ARG FEDORA_RELEASE
ARG INSTALL_GITHUB_RUNNER
ARG INSTALL_NVIDIA_OPEN
ARG RUNNER_VERSION
ARG RUNNER_SHA256
ARG UKI_CACHE_BUST=0
ARG VCONSOLE_KEYMAP

# Install the requested packages, remove server-oriented daemons that are not
# useful on a single-user desktop, and add the Noctalia/Umbriel stack.
RUN --mount=type=bind,from=scripts,source=/,target=/build-scripts \
    --mount=type=tmpfs,target=/var \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    /build-scripts/install-packages.sh

# Optional NVIDIA variant. RPM Fusion's akmod-nvidia is built as NVIDIA's open
# kernel module for the image kernel, and the module is signed with the same
# Secure Boot / MOK key as the UKI when SIGN_UKI=1. This stage needs the
# signing secrets only when enabled; the Makefile and CI always provide them.
# akmods compiles as the unprivileged `akmods` user; install-nvidia-open.sh
# sets the writable permissions that the RUN tmpfs mounts need.
RUN --mount=type=bind,from=scripts,source=/,target=/build-scripts \
    --mount=type=tmpfs,target=/var \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    if [ "${INSTALL_NVIDIA_OPEN}" = "1" ]; then \
        FEDORA_RELEASE="${FEDORA_RELEASE}" \
        UKI_CACHE_BUST="${UKI_CACHE_BUST}" \
        /build-scripts/install-nvidia-open.sh; \
    fi

# Configuration files, first-boot TUI, systemd units, skel, flatpak remotes.
COPY rootfs/ /

# Users, systemd presets, authselect, vconsole/locale defaults, permissions.
RUN --mount=type=bind,from=scripts,source=/,target=/build-scripts \
    --mount=type=tmpfs,target=/var \
    --mount=type=tmpfs,target=/run \
    /build-scripts/configure-system.sh

# Optional self-hosted GitHub Actions runner. The runner payload is installed
# read-only under /usr/libexec. `github-runner-setup` copies it to the runner
# user's home on demand.
RUN --mount=type=bind,from=scripts,source=/,target=/build-scripts \
    --mount=type=tmpfs,target=/var \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    /build-scripts/install-github-runner.sh

# Rebuild the initramfs after all dracut/plymouth/LUKS packages are present.
# The sealed UKI embeds this initramfs, so it must be generated here.
RUN --mount=type=bind,from=scripts,source=/,target=/build-scripts \
    --mount=type=tmpfs,target=/var \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    /build-scripts/rebuild-initramfs.sh

# Validate the image before the kernel is split out. This catches most bootc
# image mistakes early (non-empty /boot, /run, machine-id, sysusers, ...).
RUN bootc container lint --fatal-warnings

# ---------------------------------------------------------------------------
# 2. Normalize the OCI layers and xattrs
# ---------------------------------------------------------------------------
# The composefs digest embedded in the UKI must match the image as pulled and
# installed by bootc on the target. Rechunking the rootfs through chunkah
# normalizes container-storage/overlayfs xattrs (for example user.overlay.*)
# and produces clean OCI layers, which is required for the sealed digest to be
# reproducible on a different host. This mirrors the Fedora sealed-image
# reference build.
FROM quay.io/coreos/chunkah AS chunkah

RUN --mount=from=rootfs,src=/,target=/chunkah,ro \
    --mount=type=bind,target=/run/src,rw \
    rm -rf /run/src/out && \
    chunkah build \
        --max-layers 256 \
        --prune /ostree \
        --prune /sysroot/ostree \
        --output oci:/run/src/out

FROM oci:out AS rootfs-chunked

# The base image carries a 2 GiB ostree repository at /sysroot/ostree, which
# the sealed composefs deployment does not use. chunkah prunes it above, but
# `bootc container lint` still expects the /ostree -> sysroot/ostree
# compatibility link, so recreate only the empty directory and symlink.
RUN mkdir -p /sysroot/ostree && ln -sfn sysroot/ostree /ostree

# ---------------------------------------------------------------------------
# 3. Split the kernel/initramfs out of the root filesystem
# ---------------------------------------------------------------------------
FROM rootfs-chunked AS split

RUN --mount=type=bind,from=scripts,source=/,target=/build-scripts \
    --mount=type=tmpfs,target=/run \
    /build-scripts/split-kernel.sh

# The /kernel staging directory must not be part of the final image (and must
# not contribute to the composefs digest).
FROM split AS rootfs-split
RUN rm -rf /kernel

# ---------------------------------------------------------------------------
# 4. Re-sign systemd-boot before the composefs digest is computed
# ---------------------------------------------------------------------------
# Fedora 45's shim embeds the Fedora CA 20200709 while systemd-boot 262 is
# signed by the Fedora CA 20250530. Re-sign the image's systemd-boot with the
# image key so shim can verify it through MOK. This must happen before the
# composefs digest is computed, otherwise the UKI would embed a stale digest.
FROM ${TOOLS_IMAGE} AS boot-sign

RUN dnf install -y sbsigntools binutils && dnf clean all

# Sign the exact systemd-boot binary from the image rootfs, not the tools
# image's package, so package versions cannot drift.
COPY --from=rootfs-split /usr/lib/efi/systemd-boot /usr/lib/efi/systemd-boot

ARG SIGN_UKI
ARG UKI_CACHE_BUST=0

RUN --mount=type=bind,from=scripts,source=/,target=/build-scripts \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    UKI_CACHE_BUST="${UKI_CACHE_BUST}" \
    /build-scripts/sign-systemd-boot.sh

FROM rootfs-split AS rootfs-boot
COPY --from=boot-sign /out/grubx64.signed /tmp/grubx64.signed
RUN set -eux; \
    grub=$(ls -d /usr/lib/efi/systemd-boot/*/EFI/fedora/grubx64.efi | sort -V | tail -n1); \
    test -n "${grub}"; \
    install -Dm0644 /tmp/grubx64.signed "${grub}"; \
    rm -f /tmp/grubx64.signed

# ---------------------------------------------------------------------------
# 5. Build, composefs-seal and sign the UKI
# ---------------------------------------------------------------------------
FROM ${TOOLS_IMAGE} AS sealed-uki

RUN dnf install -y \
        bootc \
        systemd-ukify \
        systemd-boot-x64 \
        sbsigntools \
        binutils \
        jq \
        openssl \
    && dnf clean all

# Keep these ARGs after the dnf layer so changing the signing key does not
# invalidate the tools installation.
ARG SIGN_UKI
ARG INSTALL_NVIDIA_OPEN
ARG UKI_CACHE_BUST=0

RUN --mount=type=bind,from=scripts,source=/,target=/build-scripts \
    --mount=type=bind,from=rootfs-boot,target=/target \
    --mount=type=bind,from=split,source=/kernel,target=/kernel \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    INSTALL_NVIDIA_OPEN="${INSTALL_NVIDIA_OPEN}" \
    UKI_CACHE_BUST="${UKI_CACHE_BUST}" \
    /build-scripts/build-uki.sh

# ---------------------------------------------------------------------------
# 6. Final sealed image
# ---------------------------------------------------------------------------
FROM rootfs-boot AS final

# /boot is not part of the composefs root, so adding the UKI here does not
# change the digest that was embedded in it. The re-signed systemd-boot is
# already part of rootfs-boot, before the digest was computed.
COPY --from=sealed-uki /out/*.efi /boot/EFI/Linux/

LABEL org.opencontainers.image.title="Fedora bootc Noctalia Sealed"
LABEL org.opencontainers.image.description="Fedora bootc sealed image with Noctalia Greeter, Umbriel and Noctalia Shell"
LABEL containers.bootc="1"

ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
