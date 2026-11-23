#!/usr/bin/env bash
# Build (and optionally sign) the sealed UKI in the tools stage.
set -euxo pipefail

SIGN_UKI="${SIGN_UKI:-0}"

mapfile -t kvers < <(find /kernel -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
if [[ ${#kvers[@]} -ne 1 ]]; then
    echo "Expected exactly one kernel directory in /kernel, found: ${kvers[*]}" >&2
    exit 1
fi
kver=${kvers[0]}

mkdir -p /out

sign_args=()
if [[ "${SIGN_UKI}" == "1" ]]; then
    if [[ ! -s /run/secrets/secureboot_key ]]; then
        echo "SIGN_UKI=1 but the secureboot_key secret is empty or missing" >&2
        exit 1
    fi
    if [[ ! -s /run/secrets/secureboot_cert ]]; then
        echo "SIGN_UKI=1 but the secureboot_cert secret is empty or missing" >&2
        exit 1
    fi
    sign_args=(
        --signtool sbsign
        --secureboot-private-key /run/secrets/secureboot_key
        --secureboot-certificate /run/secrets/secureboot_cert
    )
fi

# Build the UKI manually with a single V1 composefs argument. The newer
# `bootc container ukify` emits both a V1 composefs.digest= and a V2
# composefs= fallback, which can trip the digest validation during install on
# a V1 composefs repository. The manual flow is the same one used by the
# Fedora sealed-image reference builds.
digest=$(bootc container compute-composefs-digest /target)
printf 'composefs=%s rw quiet rhgb loglevel=3 systemd.show_status=0\n' "${digest}" >/tmp/cmdline
ukify build \
    --linux "/kernel/${kver}/vmlinuz" \
    --initrd "/kernel/${kver}/initramfs.img" \
    --uname "${kver}" \
    --cmdline @/tmp/cmdline \
    --os-release @/target/usr/lib/os-release \
    --measure \
    --output "/out/${kver}.efi" \
    "${sign_args[@]}"

test -s "/out/${kver}.efi"
echo "Built /out/${kver}.efi (signed=${SIGN_UKI})"
