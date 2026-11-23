#!/usr/bin/env bash
# Install the sealed container image to a real disk with LUKS2 full-disk
# encryption and a shim -> systemd-boot -> UKI boot chain.
#
# This script is intended to be run from a Fedora live environment (or another
# environment with podman, systemd-repart, cryptsetup, e2fsprogs, efibootmgr
# and mokutil). It erases the target disk.
#
# Example:
#   sudo ./scripts/install-sealed.sh \
#     --image ghcr.io/owner/fedora-bootc-noctalia-sealed:latest \
#     --disk /dev/nvme0n1 \
#     --mok-cert keys/secureboot.cer
set -euo pipefail

IMAGE=""
DISK=""
MOK_CERT=""
REPART_DIR=""
REPART_TMP=""
INSECURE_REGISTRY=0
SKIP_PULL=0

usage() {
    cat <<'EOF'
Usage: install-sealed.sh --image IMAGE --disk DEVICE [options]

Options:
  --image IMAGE        Sealed bootc container image reference
  --disk DEVICE        Target block device (e.g. /dev/nvme0n1)
  --mok-cert PATH      Optional DER/PEM certificate to queue for MOK enrollment
  --repart-dir DIR     systemd-repart definition directory
                       (default: ../repart.d next to this script)
  --insecure-registry  Skip TLS verification for the initial podman pull
                       (for the local HTTP registry in scripts/local-registry.sh)
  --skip-pull          Do not pull the image; use an image already present in
                       local Podman storage (useful inside a VM with a loaded tar)
  -h, --help           Show this help

WARNING: this erases the target disk.
EOF
}

while (($# > 0)); do
    case "$1" in
        --image) IMAGE=${2-}; shift 2 ;;
        --disk) DISK=${2-}; shift 2 ;;
        --mok-cert) MOK_CERT=${2-}; shift 2 ;;
        --repart-dir) REPART_DIR=${2-}; shift 2 ;;
        --insecure-registry) INSECURE_REGISTRY=1; shift ;;
        --skip-pull) SKIP_PULL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -n "${IMAGE}" && -n "${DISK}" ]] || { usage >&2; exit 1; }
[[ -b "${DISK}" ]] || { echo "${DISK} is not a block device" >&2; exit 1; }

for tool in podman systemd-repart cryptsetup mkfs.ext4 mount umount mountpoint \
    wipefs lsblk udevadm efibootmgr; do
    command -v "${tool}" >/dev/null || { echo "Missing required tool: ${tool}" >&2; exit 1; }
done

if mountpoint -q /mnt; then
    echo "/mnt is already a mountpoint; refusing to continue." >&2
    exit 1
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
REPART_DIR=${REPART_DIR:-"${script_dir}/../repart.d"}
if [[ ! -d "${REPART_DIR}" ]]; then
    # Standalone fallback: the script can be copied to a VM without the repo.
    REPART_TMP="$(mktemp -d)"
    REPART_DIR="${REPART_TMP}"
    cat >"${REPART_DIR}/01-esp.conf" <<'EOF'
[Partition]
Type=esp
Format=vfat
SizeMinBytes=2G
SizeMaxBytes=2G
EOF
    cat >"${REPART_DIR}/02-root.conf" <<'EOF'
[Partition]
Type=root
Label=root
SizeMinBytes=10G
EOF
fi

cleanup() {
    set +e
    umount /mnt/boot 2>/dev/null
    umount /mnt 2>/dev/null
    cryptsetup close root 2>/dev/null
    [[ -n "${REPART_TMP:-}" ]] && rm -rf "${REPART_TMP}"
}
trap cleanup EXIT

echo "Target disk: ${DISK}"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "${DISK}" || true
echo
read -r -p "Type exactly 'ERASE ${DISK}' to continue: " confirm
[[ "${confirm}" == "ERASE ${DISK}" ]] || { echo "Aborted." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Partitioning (ESP + unformatted root partition with the discoverable root
# GPT type so systemd-gpt-auto-generator can unlock it as /dev/mapper/root).
# ---------------------------------------------------------------------------
wipefs -a "${DISK}"
systemd-repart --empty=force --definitions="${REPART_DIR}" \
    --dry-run=no --discard=no "${DISK}"
udevadm settle

if [[ "${DISK}" =~ [0-9]$ ]]; then
    esp="${DISK}p1"
    root="${DISK}p2"
else
    esp="${DISK}1"
    root="${DISK}2"
fi

# ---------------------------------------------------------------------------
# LUKS2 + ext4 with fs-verity
# ---------------------------------------------------------------------------
cryptsetup luksFormat --type luks2 --label luks-root "${root}"
cryptsetup open "${root}" root

mkfs.ext4 -O verity -L root /dev/mapper/root

mount /dev/mapper/root /mnt
mkdir -p /mnt/boot
mount "${esp}" /mnt/boot

# ---------------------------------------------------------------------------
# bootc install (composefs backend, systemd-boot, no finalize yet)
# ---------------------------------------------------------------------------
if [[ ${SKIP_PULL} -eq 1 ]]; then
    podman image exists "${IMAGE}" >/dev/null 2>&1 || {
        echo "Image '${IMAGE}' is not in local Podman storage." >&2
        echo "Load it with 'podman load -i <image.tar>' or omit --skip-pull." >&2
        exit 1
    }
    echo "Using local image: ${IMAGE}"
else
    pull_args=()
    if [[ ${INSECURE_REGISTRY} -eq 1 ]]; then
        pull_args+=(--tls-verify=false)
    fi
    podman pull "${pull_args[@]}" "${IMAGE}"
fi

podman run --rm --privileged --pid=host --ipc=host \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v /:/run/host \
    "${IMAGE}" \
    bootc install to-filesystem \
        --source-imgref="containers-storage:${IMAGE}" \
        --bootloader=systemd \
        --composefs-backend \
        --skip-finalize \
        /run/host/mnt

# ---------------------------------------------------------------------------
# Install shim and use the Fedora-signed systemd-boot as shim's second stage.
# ---------------------------------------------------------------------------
# Two container quirks are handled here:
#  - The image's /mnt is a symlink to var/mnt, which does not exist in the
#    container rootfs; mounting the target at /var/mnt makes /mnt resolve.
#  - The ESP is vfat and cannot carry an SELinux label, so the container must
#    run unconfined to read it (same as the bootc install step above).
podman run --rm --security-opt label=type:unconfined_t \
    -v /mnt:/var/mnt:z "${IMAGE}" bash -euxc '
    shimdir=$(ls -d /usr/lib/efi/shim/* | sort -V | tail -n1)
    signed_grub=$(ls -d /usr/lib/efi/systemd-boot/*/EFI/fedora/grubx64.efi | sort -V | tail -n1)
    install -d /mnt/boot/EFI/fedora /mnt/boot/EFI/BOOT
    cp -a "${shimdir}/EFI/fedora/." /mnt/boot/EFI/fedora/
    cp -a "${shimdir}/EFI/BOOT/." /mnt/boot/EFI/BOOT/
    install -Dm0644 "${shimdir}/EFI/fedora/mmx64.efi" /mnt/boot/EFI/BOOT/mmx64.efi
    install -Dm0644 /mnt/boot/EFI/systemd/systemd-bootx64.efi /mnt/boot/EFI/fedora/grubx64.efi
    install -Dm0644 /mnt/boot/EFI/systemd/systemd-bootx64.efi /mnt/boot/EFI/BOOT/grubx64.efi
    if [ -f "${signed_grub}" ]; then
        install -Dm0644 "${signed_grub}" /mnt/boot/EFI/fedora/grubx64.efi
        install -Dm0644 "${signed_grub}" /mnt/boot/EFI/BOOT/grubx64.efi
    fi
'

# Remove boot entries that point directly at systemd-boot: with Secure Boot
# they must go through shim.
while read -r bootnum; do
    [[ -n "${bootnum}" ]] && efibootmgr -b "${bootnum}" -B
done < <(efibootmgr | awk '/systemd-boot/ {gsub(/Boot/,"",$1); gsub(/\*/,"",$1); print $1}')

efibootmgr --create --disk "${DISK}" --part 1 \
    --label "Fedora Noctalia Sealed" \
    --loader '\EFI\fedora\shimx64.efi'

newnum=$(efibootmgr | awk '/Fedora Noctalia Sealed/ {gsub(/Boot/,"",$1); gsub(/\*/,"",$1); print $1; exit}')
if [[ -n "${newnum}" ]]; then
    order=$(efibootmgr | awk '/^BootOrder:/ {print $2}')
    order=$(printf '%s' "${order}" | tr ',' '\n' | grep -vx "${newnum}" | paste -sd, -)
    efibootmgr -o "${newnum},${order}"
fi

if [[ -n "${MOK_CERT}" ]]; then
    command -v mokutil >/dev/null || { echo "Missing required tool: mokutil" >&2; exit 1; }
    [[ -f "${MOK_CERT}" ]] || { echo "Missing MOK certificate: ${MOK_CERT}" >&2; exit 1; }
    mokutil --import "${MOK_CERT}"
fi

sync
cleanup

cat <<EOF

Installation complete.

Next steps:
  1. Reboot. If a MOK certificate was imported, complete enrollment in
     MokManager (the password you just entered) on the next boot.
  2. At the first-boot TUI, create your user and set hostname/timezone.
  3. Enroll LUKS unlock methods (run as root on the installed system):

       # TPM2 (PCR 7 = Secure Boot state, PCR 11 = UKI measurement)
       systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11 ${root}

       # FIDO2 with PIN
       systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes ${root}

       # TPM2 + PIN
       systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes --tpm2-pcrs=7+11 ${root}

  The passphrase keyslot remains as a recovery method.
EOF
