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

## Japanese input

fcitx5 with the Mozc engine is installed and started with the Umbriel
session. Press Ctrl+Space (or Zenkaku_Hankaku on a Japanese keyboard) to
toggle Japanese input. Run `fcitx5-configtool` to change engines, keybinds or
Mozc settings. The system default profile is `/etc/xdg/fcitx5/profile`;
`~/.config/fcitx5/profile` overrides it when present.

## LUKS unlock enrollment

On the installed system, as root. Signed images embed `.pcrsig`/`.pcrpkey`;
the recommended daily unlock is PIN + TPM2 with the public-key policy
(effective PCR 7+11+14; no TPM2 re-enrollment on UKI updates):

```bash
openssl x509 -in secureboot.crt -pubkey -noout > secureboot.pub.pem
systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes \
  --tpm2-pcrs=7+14 \
  --tpm2-public-key=secureboot.pub.pem \
  --tpm2-public-key-pcrs=11 /dev/nvme0n1p2

# Unsigned/custom image or fallback: fixed PCR 7+11+14
systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes \
  --tpm2-pcrs=7+11+14 /dev/nvme0n1p2

# TPM2 without PIN (convenience; less recommended)
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11+14 /dev/nvme0n1p2

# FIDO2 with PIN
systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/nvme0n1p2
```

Keep the original passphrase keyslot as a recovery method.

PCR 14 covers MOK changes (Evil Maid with a MOK-enrolled key). Signed images
embed `.pcrsig`/`.pcrpkey`; unsigned builds can use a standalone
`tpm2-pcr-signature.json` in `/etc/systemd/`. See repository README 6.5.

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
