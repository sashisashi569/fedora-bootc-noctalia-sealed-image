#!/usr/bin/env bash
# Install RPM Fusion's NVIDIA driver and build the open kernel modules for the
# image kernel. The modules are signed with the Secure Boot / MOK key when the
# build provides one, so the MOK enrollment that trusts the UKI also trusts the
# NVIDIA modules.
set -euxo pipefail

FEDORA_RELEASE="${FEDORA_RELEASE:-$(rpm -E %fedora)}"
SECRETS_DIR="${SECRETS_DIR:-/run/secrets}"

mapfile -t kvers < <(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
if [[ ${#kvers[@]} -ne 1 ]]; then
    echo "Expected exactly one kernel version, found: ${kvers[*]}" >&2
    exit 1
fi
kver=${kvers[0]}

# Buildah's RUN tmpfs mounts are not necessarily mode 1777, and akmods builds
# as the unprivileged `akmods` user. Make the temporary directories writable.
mkdir -p /tmp /var/tmp
chmod 1777 /tmp /var/tmp

# RPM Fusion Nonfree carries the NVIDIA driver. The release package also
# installs the RPM Fusion GPG keys, so the driver packages below are verified.
# Only the release package is installed without a GPG check because its key is
# not available yet (the same bootstrap pattern as Terra above).
dnf install -y --nogpgcheck \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# `sdubby` provides the grubby-compatible command used by the NVIDIA package
# scriptlets and by akmods, but writes systemd-boot entries instead of GRUB
# ones. Installing it keeps the sealed image on systemd-boot.
#
# Install the build tools before akmod-nvidia so the signing key and the open
# module macro below are in place before the akmod package's %posttrans starts
# its background build.
dnf install -y --refresh --allowerasing \
    sdubby \
    akmods \
    "kernel-devel-${kver}"

# Force the open kernel module tree even if the build host exposes a GPU that
# RPM Fusion would otherwise classify as needing the proprietary module.
# RPM Fusion explicitly supports this override; it is not used by default so
# that non-NVIDIA images remain unchanged.
mkdir -p /etc/rpm
cat >/etc/rpm/macros.nvidia-open <<'EOF'
# Build only NVIDIA's open GPU kernel modules.
%_with_kmod_nvidia_open 1
EOF

# akmods/kmodtool sign modules with the key pair in /etc/pki/akmods. Reuse the
# image's Secure Boot / MOK key so no additional MOK enrollment is needed.
# The private key is removed again at the end of this script.
if [[ -s "${SECRETS_DIR}/secureboot_key" && -s "${SECRETS_DIR}/secureboot_cert" ]]; then
    install -d -m 0750 -o root -g akmods /etc/pki/akmods/certs /etc/pki/akmods/private
    install -m 0640 -o root -g akmods \
        "${SECRETS_DIR}/secureboot_key" /etc/pki/akmods/private/private_key.priv
    openssl x509 -in "${SECRETS_DIR}/secureboot_cert" -outform DER \
        -out /etc/pki/akmods/certs/public_key.der
    chown root:akmods /etc/pki/akmods/certs/public_key.der
    chmod 0644 /etc/pki/akmods/certs/public_key.der
else
    echo "No Secure Boot key/cert provided; NVIDIA modules will be unsigned." >&2
    rm -f /etc/pki/akmods/private/private_key.priv \
        /etc/pki/akmods/certs/public_key.der
fi

# `akmod-nvidia` builds NVIDIA's open kernel modules. The generated kmod is
# installed below /usr/lib/modules and is therefore part of the sealed root
# filesystem. `xorg-x11-drv-nvidia` is the matching proprietary user-space
# driver; the "open" part is the kernel module only.
dnf install -y --refresh --allowerasing \
    akmod-nvidia \
    xorg-x11-drv-nvidia \
    xorg-x11-drv-nvidia-power

# The akmod package starts a background build in its %posttrans scriptlet.
# The signing key and the open-module macro above are already in place, so
# either that build or this synchronous one produces the signed open module.
# Do not use --rebuild here: it invokes `dnf reinstall`, which does nothing
# when no previous kmod package is installed, leaving the image without the
# module.
akmods --force --kernels "${kver}"

# Update modules.dep and other module metadata for the image kernel. The
# kmod RPM's %post cannot do this during the build because uname -r is the
# build host's kernel, not the image kernel.
depmod -a "${kver}"

# Fail early if the module is missing or is not NVIDIA's open implementation.
modinfo -k "${kver}" -F filename nvidia
modinfo -k "${kver}" -F license nvidia | grep -Fx 'Dual MIT/GPL'

if [[ -s "${SECRETS_DIR}/secureboot_key" && -s "${SECRETS_DIR}/secureboot_cert" ]]; then
    signer=$(modinfo -k "${kver}" -F signer nvidia)
    [[ -n "${signer}" ]]
    printf '%s\n' "${signer}"
fi

# Keep nouveau from binding the GPU before the NVIDIA modules are loaded.
mkdir -p /usr/lib/modprobe.d
cat >/usr/lib/modprobe.d/50-nvidia-blacklist-nouveau.conf <<'EOF'
blacklist nouveau
blacklist nova_core
EOF

# Keep bootc's kernel-argument database in sync for installs/upgrades that
# apply kargs.d. The sealed UKI itself is built from build-uki.sh, which adds
# the same arguments when INSTALL_NVIDIA_OPEN=1.
mkdir -p /usr/lib/bootc/kargs.d
cat >/usr/lib/bootc/kargs.d/20-nvidia.toml <<'EOF'
# Blacklist the in-kernel NVIDIA drivers so the NVIDIA modules can bind the
# GPU, and enable DRM kernel modesetting for Wayland.
kargs = ["rd.driver.blacklist=nouveau,nova_core", "modprobe.blacklist=nouveau,nova_core", "nvidia-drm.modeset=1"]
EOF

# The module is signed; the image does not need the private key at runtime.
rm -f /etc/pki/akmods/private/private_key.priv \
    /etc/pki/akmods/certs/public_key.der

# sdubby ships a skeleton /boot/efi tree for systemd-boot. The sealed image
# installs its own loader entries, and /boot must stay empty in the container
# image (it is masked by the ESP at runtime).
rm -rf /boot/efi

rm -rf /var/cache/akmods /var/cache/dnf /var/cache/libdnf5 /var/lib/dnf
