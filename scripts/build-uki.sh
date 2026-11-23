#!/usr/bin/env bash
# Build (and optionally sign + PCR-attest) the sealed UKI in the tools stage.
set -euxo pipefail

SIGN_UKI="${SIGN_UKI:-0}"

mapfile -t kvers < <(find /kernel -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
if [[ ${#kvers[@]} -ne 1 ]]; then
    echo "Expected exactly one kernel directory in /kernel, found: ${kvers[*]}" >&2
    exit 1
fi
kver=${kvers[0]}

mkdir -p /out

if [[ "${SIGN_UKI}" == "1" ]]; then
    if [[ ! -s /run/secrets/secureboot_key ]]; then
        echo "SIGN_UKI=1 but the secureboot_key secret is empty or missing" >&2
        exit 1
    fi
    if [[ ! -s /run/secrets/secureboot_cert ]]; then
        echo "SIGN_UKI=1 but the secureboot_cert secret is empty or missing" >&2
        exit 1
    fi
fi

# Build the UKI manually with a single V1 composefs argument. The newer
# `bootc container ukify` emits both a V1 composefs.digest= and a V2
# composefs= fallback, which can trip the digest validation during install on
# a V1 composefs repository. The manual flow is the same one used by the
# Fedora sealed-image reference builds.
digest=$(bootc container compute-composefs-digest /target)
printf 'composefs=%s rw quiet rhgb loglevel=3 systemd.show_status=0\n' "${digest}" >/tmp/cmdline

if [[ "${SIGN_UKI}" == "1" ]]; then
    # 1. Build a base UKI with the public key (.pcrpkey) and obtain the PCR
    #    policy digests. The build host has no TPM, so use --policy-digest
    #    and sign the tbs values offline below.
    ukify build \
        --linux "/kernel/${kver}/vmlinuz" \
        --initrd "/kernel/${kver}/initramfs.img" \
        --uname "${kver}" \
        --cmdline @/tmp/cmdline \
        --os-release @/target/usr/lib/os-release \
        --pcr-certificate /run/secrets/secureboot_cert \
        --pcr-banks sha256 \
        --policy-digest --json=short \
        --output /tmp/uki-base.efi > /tmp/uki-base.pcrs

    # 2. Sign the PCR policy digests with the same key used for the UKI.
    python3 - /tmp/uki-base.pcrs /run/secrets/secureboot_key /tmp/uki-signed.pcrs <<'PY'
import base64
import json
import subprocess
import sys

base = json.load(open(sys.argv[1]))
for _bank, policies in base.items():
    for policy in policies:
        tbs = bytes.fromhex(policy["tbs"])
        sig = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", sys.argv[2]],
            input=tbs,
            capture_output=True,
            check=True,
        ).stdout
        policy["sig"] = base64.b64encode(sig).decode()

json.dump(base, open(sys.argv[3], "w"))
PY

    # 3. Attach the signed .pcrsig section and sign the final UKI for
    #    Secure Boot. The .pcrpkey section comes from the base UKI.
    ukify build \
        --join-pcrsig=/tmp/uki-base.efi \
        --pcrsig=@/tmp/uki-signed.pcrs \
        --output /tmp/uki.efi
    sbsign \
        --key /run/secrets/secureboot_key \
        --cert /run/secrets/secureboot_cert \
        /tmp/uki.efi --output "/out/${kver}.efi"
    sbverify --cert /run/secrets/secureboot_cert "/out/${kver}.efi"
    ukify --section=.pcrsig:binary --section=.pcrpkey:binary \
        inspect "/out/${kver}.efi" >/tmp/uki-sections.txt
    grep -q '\.pcrsig' /tmp/uki-sections.txt
    grep -q '\.pcrpkey' /tmp/uki-sections.txt
else
    # Unsigned build: no PCR signature is embedded. Use the fixed
    # PCR 7+11+14 enrollment, or provide a standalone
    # tpm2-pcr-signature.json on the installed system.
    ukify build \
        --linux "/kernel/${kver}/vmlinuz" \
        --initrd "/kernel/${kver}/initramfs.img" \
        --uname "${kver}" \
        --cmdline @/tmp/cmdline \
        --os-release @/target/usr/lib/os-release \
        --measure \
        --output "/out/${kver}.efi"
fi

test -s "/out/${kver}.efi"
echo "Built /out/${kver}.efi (signed=${SIGN_UKI})"
