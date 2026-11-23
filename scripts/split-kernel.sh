#!/usr/bin/env bash
# Move the kernel and initramfs out of the root filesystem so they can be
# embedded into the UKI. Uses bootc's helper when available and falls back to
# the equivalent manual move for older bootc releases.
set -euxo pipefail

mkdir -p /kernel

if bootc container split-kernel-and-rootfs --help >/dev/null 2>&1; then
    bootc container split-kernel-and-rootfs --rootfs / --output /kernel
else
    kver=$(cd /usr/lib/modules && echo *)
    mkdir -p "/kernel/${kver}"
    mv "/usr/lib/modules/${kver}/vmlinuz" "/kernel/${kver}/vmlinuz"
    mv "/usr/lib/modules/${kver}/initramfs.img" "/kernel/${kver}/initramfs.img"
fi
