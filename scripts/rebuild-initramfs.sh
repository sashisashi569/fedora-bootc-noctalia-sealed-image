#!/usr/bin/env bash
# Regenerate the initramfs that will be embedded in the sealed UKI.
set -euxo pipefail

# /var is a tmpfs during the container build; dracut wants /var/tmp.
mkdir -p /var/tmp /var/cache /var/lib

mapfile -t kvers < <(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
if [[ ${#kvers[@]} -ne 1 ]]; then
    echo "Expected exactly one kernel version, found: ${kvers[*]}" >&2
    exit 1
fi
kver=${kvers[0]}

dracut \
    --force \
    --verbose \
    --no-hostonly \
    --install "/etc/passwd /etc/group" \
    "/usr/lib/modules/${kver}/initramfs.img" \
    "${kver}"
