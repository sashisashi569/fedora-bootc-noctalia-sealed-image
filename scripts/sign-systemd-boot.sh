#!/usr/bin/env bash
# Re-sign the image's systemd-boot with the image Secure Boot key.
#
# Fedora 45's shim embeds the Fedora vendor CA 20200709, while the
# systemd-boot 262 package is signed by the Fedora CA 20250530. The shim
# therefore rejects the stock systemd-boot under Secure Boot. Sign it with
# the same key as the UKI; the installer imports the matching certificate
# into MOK, so shim verifies systemd-boot and the UKI through MOK.
set -euxo pipefail

SIGN_UKI="${SIGN_UKI:-0}"

mkdir -p /out

grub=$(find /usr/lib/efi/systemd-boot -path '*/EFI/fedora/grubx64.efi' -type f | sort -V | tail -n1)
if [[ -z "${grub}" ]]; then
    echo "systemd-boot grubx64.efi not found in the image rootfs" >&2
    exit 1
fi

if [[ "${SIGN_UKI}" == "1" ]]; then
    if [[ ! -s /run/secrets/secureboot_key ]]; then
        echo "SIGN_UKI=1 but the secureboot_key secret is empty or missing" >&2
        exit 1
    fi
    if [[ ! -s /run/secrets/secureboot_cert ]]; then
        echo "SIGN_UKI=1 but the secureboot_cert secret is empty or missing" >&2
        exit 1
    fi

    # Remove the Fedora signature first. A mixed signature table is
    # ambiguous; sign only with the image key, which MOK trusts.
    cp "${grub}" /tmp/grubx64.unsigned.efi
    sbattach --remove /tmp/grubx64.unsigned.efi
    sbsign \
        --key /run/secrets/secureboot_key \
        --cert /run/secrets/secureboot_cert \
        /tmp/grubx64.unsigned.efi --output /out/grubx64.signed
    sbverify --cert /run/secrets/secureboot_cert /out/grubx64.signed
else
    # Unsigned builds keep the Fedora-signed systemd-boot.
    cp "${grub}" /out/grubx64.signed
fi

test -s /out/grubx64.signed
echo "Built /out/grubx64.signed (signed=${SIGN_UKI})"
