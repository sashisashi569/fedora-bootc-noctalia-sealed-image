#!/usr/bin/env bash
# Install and remove packages inside the Fedora bootc root filesystem.
set -euxo pipefail

# ---------------------------------------------------------------------------
# Repositories
# ---------------------------------------------------------------------------
# No proprietary codecs in the image.
rm -f /etc/yum.repos.d/fedora-cisco-openh264.repo

# Terra carries Umbriel, Noctalia Greeter, the Umbriel portal and OpenCode.
# terra-release installs Terra's signing key; only this bootstrap package is
# installed with GPG checking disabled (as recommended by Terra/Noctalia).
# The $releasever expression is intentionally expanded by dnf, not the shell.
dnf install -y --nogpgcheck \
    --repofrompath "terra,https://repos.fyralabs.com/terra\$releasever" \
    terra-release

# ---------------------------------------------------------------------------
# Bootloader: replace bootupd/GRUB with systemd-boot
# ---------------------------------------------------------------------------
# Sealed images must not contain bootupd (bootc then selects systemd-boot).
rpm -e --nodeps bootupd 2>/dev/null || true
rpm -e --nodeps sdubby 2>/dev/null || true

mapfile -t grub_pkgs < <(rpm -qa 'grub2*' 2>/dev/null || true)
if ((${#grub_pkgs[@]} > 0)); then
    rpm -e --nodeps "${grub_pkgs[@]}"
fi
rm -rf /usr/lib/bootupd /usr/lib/ostree-boot

# The signed package provides /usr/lib/systemd/boot/efi/systemd-bootx64.efi.
# It conflicts with, or is confused by, the unsigned package.
rpm -e --nodeps systemd-boot-unsigned 2>/dev/null || true

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
# Explicitly requested packages, Noctalia family, desktop applications, and the
# runtime pieces needed by them (audio, portals, keyring, LUKS/FIDO2/TPM2,
# Plymouth, Secure Boot tooling, GitHub Actions runner dependencies).
dnf install -y --refresh --allowerasing \
    nix-core \
    vim vim-X11 git tree \
    opencode \
    flatpak \
    systemd \
    dialog \
    kitty firefox Thunar thunar-volman tumbler gvfs gvfs-mtp udisks2 \
    mpv mpv-mpris seahorse \
    noctalia umbriel-nightly noctalia-greeter greetd xwayland-satellite \
    xdg-desktop-portal xdg-desktop-portal-gtk \
    xdg-desktop-portal-umbriel-nightly \
    accountsservice authselect polkit \
    pipewire pipewire-pulseaudio wireplumber \
    bluez bluez-tools \
    gnome-keyring gnome-keyring-pam libsecret \
    NetworkManager nm-connection-editor \
    firewalld chrony \
    brightnessctl playerctl \
    grim slurp wl-clipboard \
    xdg-user-dirs xdg-utils \
    default-fonts google-noto-emoji-fonts \
    glibc-langpack-en glibc-langpack-ja \
    plymouth plymouth-system-theme plymouth-theme-spinner \
    systemd-boot-x64 shim-x64 efibootmgr mokutil sbsigntools systemd-ukify \
    cryptsetup tpm2-tss tpm2-tools fido2-tools fsverity-utils \
    e2fsprogs xfsprogs btrfs-progs dosfstools \
    curl libicu lttng-ust libunwind \
    dracut

# ---------------------------------------------------------------------------
# Remove server-oriented daemons and cloud/enterprise plumbing
# ---------------------------------------------------------------------------
remove_if_installed() {
    local p
    local -a pkgs=()
    for p in "$@"; do
        if rpm -q "$p" >/dev/null 2>&1; then
            pkgs+=("$p")
        fi
    done
    if ((${#pkgs[@]} > 0)); then
        dnf remove -y "${pkgs[@]}" || true
    fi
}

remove_if_installed \
    sssd-client sssd-ad sssd-ipa sssd-krb5 sssd-ldap libsss_sudo \
    sos \
    irqbalance \
    WALinuxAgent-udev \
    NetworkManager-cloud-setup \
    cloud-utils-growpart \
    clevis clevis-dracut clevis-pin-tpm2 clevis-luks \
    kexec-tools makedumpfile kdump-utils \
    console-login-helper-messages-issuegen \
    console-login-helper-messages-profile \
    stalld sg3_utils \
    openssh-server \
    nano \
    dnf-automatic \
    rsyslog at \
    cockpit cockpit-ws cockpit-bridge cockpit-system \
    pcp pcp-selinux tuned \
    httpd mod_ssl postfix sendmail \
    mariadb-server postgresql-server redis \
    samba \
    unbound bind dhcp-server tftp-server vsftpd xinetd \
    iscsi-initiator-utils device-mapper-multipath \
    autofs \
    systemd-networkd systemd-networkd-defaults

# NOTE: nfs-utils, samba-common and mdadm are intentionally kept because
# gvfs/Thunar/udisks2/mpv depend on their client libraries. Their server
# daemons are masked in configure-system.sh instead.

# rpm-ostree is not used by the composefs/sealed backend.
remove_if_installed rpm-ostree rpm-ostree-libs

# Keep the image from shipping a stale rescue initramfs.
remove_if_installed dracut-config-rescue

dnf clean all
rm -rf /var/cache/dnf /var/cache/libdnf5 /var/lib/dnf
