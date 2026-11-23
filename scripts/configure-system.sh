#!/usr/bin/env bash
# Configure the installed root filesystem.
set -euxo pipefail

VCONSOLE_KEYMAP="${VCONSOLE_KEYMAP:-us}"

# ---------------------------------------------------------------------------
# System users
# ---------------------------------------------------------------------------
# greetd's RPM declares its user via sysusers. The GitHub Actions runner user
# is declared in /usr/lib/sysusers.d/github-runner.conf and created at boot by
# systemd-sysusers. No users are written to /etc/passwd during the build.
#
# The greeter runs its own wlroots compositor. pam_systemd (patched below)
# normally gives the greetd session DRM/input access through logind, but the
# supplementary groups make direct device access work as well. The groups live
# in /usr/lib/group (nss-altfiles), so usermod cannot edit them; create /etc
# group overrides that merge in greetd.
add_user_to_group() {
    local user=$1 group=$2 line
    line=$(getent group "${group}") || return 0
    if printf '%s\n' "${line}" | cut -d: -f4 | tr ',' '\n' | grep -Fxq "${user}"; then
        return 0
    fi
    if grep -q "^${group}:" /etc/group; then
        awk -F: -v OFS=: -v g="${group}" -v u="${user}" '
            $1 == g {
                if ($4 == "") $4 = u
                else if (index("," $4 ",", "," u ",") == 0) $4 = $4 "," u
            }
            { print }
        ' /etc/group >/etc/group.new
        mv /etc/group.new /etc/group
    else
        printf '%s\n' "${line}" | awk -F: -v OFS=: -v u="${user}" '
            {
                if ($4 == "") $4 = u
                else if (index("," $4 ",", "," u ",") == 0) $4 = $4 "," u
                print
            }
        ' >>/etc/group
    fi
}

for group in video render input; do
    if getent group "${group}" >/dev/null && getent passwd greetd >/dev/null; then
        add_user_to_group greetd "${group}"
    fi
done

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
# Avoid two competing first-boot prompts: the image provides its own TUI.
systemctl mask systemd-firstboot.service systemd-homed-firstboot.service || true

# The sealed image uses systemd-boot, not bootupd/GRUB.
systemctl mask bootloader-update.service || true

# nfs-utils / samba-common / mdadm remain for their client libraries
# (gvfs, Thunar, udisks2), but their server/monitoring daemons are disabled.
for unit in \
    nfs-server.service nfs-utils.service \
    rpcbind.service rpcbind.socket \
    mdmonitor.service \
    smb.service nmb.service; do
    systemctl mask "${unit}" 2>/dev/null || true
done

systemctl enable \
    initial-firstboot.service \
    noctalia-greeter-setup.service \
    greetd.service \
    systemd-homed.service \
    systemd-boot-update.service \
    sync-shim-systemd-boot.service \
    github-runner.service \
    bluetooth.service \
    accounts-daemon.service \
    udisks2.service \
    firewalld.service \
    chronyd.service

systemctl set-default graphical.target

# PipeWire/WirePlumber user sessions (RPM presets normally cover this).
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# Authentication: enable systemd-homed PAM/NSS integration
# ---------------------------------------------------------------------------
# `local` is the plain local-files profile; the feature adds pam_systemd_home
# and nss-systemd so homectl users can log in through greetd.
authselect select local --force
authselect enable-feature with-systemd-homed

# bootc image mode depends on nss-altfiles (/usr/lib/passwd, /usr/lib/group).
# The base image's local profile already includes the altfiles module; keep a
# hard check so a future authselect change cannot silently break sysusers.
grep -Eq '^passwd:.*[[:space:]]altfiles([[:space:]]|$)' /etc/nsswitch.conf
grep -Eq '^group:.*[[:space:]]altfiles([[:space:]]|$)' /etc/nsswitch.conf

# ---------------------------------------------------------------------------
# greetd PAM: add pam_systemd.so to the greetd PAM stack
# ---------------------------------------------------------------------------
# Noctalia Greeter's session wrapper needs a logind session. The helper is
# idempotent and only edits /etc/pam.d/greetd.
if [[ -x /usr/share/noctalia-greeter/setup_greetd_pam.sh ]]; then
    /usr/share/noctalia-greeter/setup_greetd_pam.sh
    rm -f /etc/pam.d/greetd.bak.noctalia.*
fi

# ---------------------------------------------------------------------------
# Bootloader: use the Fedora-signed systemd-boot at the standard path
# ---------------------------------------------------------------------------
# systemd-ukify pulls in systemd-boot-unsigned, while systemd-boot-x64 ships
# the signed binary as systemd-bootx64.efi.signed. bootc installs the standard
# path, so replace the unsigned file with the signed one (and drop the
# unsigned package entirely).
if [[ -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed ]]; then
    install -m 0644 \
        /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
        /usr/lib/systemd/boot/efi/systemd-bootx64.efi
fi

# ---------------------------------------------------------------------------
# Console / locale / keymap
# ---------------------------------------------------------------------------
# This keymap is baked into the sealed initramfs and is used for the LUKS
# passphrase/PIN prompt. Change it at build time with --build-arg
# VCONSOLE_KEYMAP=... and rebuild the image.
cat >/etc/vconsole.conf <<EOF
KEYMAP=${VCONSOLE_KEYMAP}
EOF

cat >/etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
EOF

ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# ---------------------------------------------------------------------------
# Plymouth
# ---------------------------------------------------------------------------
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme spinner
fi

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
chmod 0755 \
    /usr/libexec/initial-firstboot \
    /usr/libexec/github-runner-setup \
    /usr/libexec/sync-shim-systemd-boot

# ---------------------------------------------------------------------------
# Cleanup of build-only content
# ---------------------------------------------------------------------------
rm -rf /var/cache/dnf /var/cache/libdnf5 /var/lib/dnf /tmp/* /var/tmp/*
