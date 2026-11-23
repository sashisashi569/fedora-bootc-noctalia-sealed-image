# Fedora bootc Noctalia sealed image

This image boots through:

```text
UEFI -> shim -> systemd-boot -> UKI (kernel + initramfs + composefs digest) -> systemd
```

The root filesystem is composefs + fs-verity. LUKS2 full-disk encryption is
created by the installer; systemd-gpt-auto-generator unlocks the discoverable
root partition as /dev/mapper/root.

## First boot

The `initial-firstboot.service` TUI runs on tty1 before greetd and configures
hostname, timezone, locale, keyboard and the first administrator user. It runs
only once (`/var/lib/initial-firstboot/complete`).

## LUKS unlock enrollment

On the installed system, as root:

```bash
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11 /dev/nvme0n1p2
systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/nvme0n1p2
systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes --tpm2-pcrs=7+11 /dev/nvme0n1p2
```

Keep the original passphrase keyslot as a recovery method.

## GitHub Actions runner

```bash
github-runner-setup --url https://github.com/OWNER/REPO --token TOKEN
```

The runner runs as the `github-runner` user from
`/var/home/github-runner/actions-runner`.

## Useful checks

```bash
bootc status
mokutil --sb-state
mokutil --list-enrolled
sbverify --cert /path/to/secureboot.crt /boot/EFI/Linux/*.efi
bootctl status
systemctl status greetd
journalctl -u greetd -b
```
