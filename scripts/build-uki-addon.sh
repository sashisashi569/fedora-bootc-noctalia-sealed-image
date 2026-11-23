#!/usr/bin/env bash
# Build a signed UKI addon to add kernel arguments without rebuilding the UKI.
#
# Example:
#   ./scripts/build-uki-addon.sh keymap-jp "vconsole.keymap=jp106"
#
# Install the resulting addon on the ESP:
#   /boot/loader/addons/<name>.addon.efi              (all UKIs)
#   /boot/EFI/Linux/<uki>.efi.extra.d/<name>.addon.efi (one UKI)
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 NAME \"KERNEL ARGUMENTS\" [OUTPUT_DIR] [KEY] [CERT]" >&2
    exit 1
fi

name=$1
cmdline=$2
outdir=${3:-.}
key=${4:-keys/secureboot.key}
cert=${5:-keys/secureboot.crt}

if [[ ! -s "${key}" || ! -s "${cert}" ]]; then
    echo "Missing ${key} or ${cert}" >&2
    exit 1
fi

mkdir -p "${outdir}"

ukify build \
    --cmdline "${cmdline}" \
    --signtool sbsign \
    --secureboot-private-key "${key}" \
    --secureboot-certificate "${cert}" \
    --output "${outdir}/${name}.addon.efi"

echo "Wrote ${outdir}/${name}.addon.efi"
