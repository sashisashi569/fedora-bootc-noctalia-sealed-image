#!/usr/bin/env bash
# Generate a Secure Boot / MOK key pair for signing the sealed UKI.
#
# These are build-time secrets. Never commit the private key.
set -euo pipefail

outdir=${1:-keys}
mkdir -p "${outdir}"

if [[ -s "${outdir}/secureboot.key" || -s "${outdir}/secureboot.crt" ]]; then
    echo "Refusing to overwrite non-empty keys in ${outdir}" >&2
    exit 1
fi
rm -f "${outdir}/secureboot.key" "${outdir}/secureboot.crt" "${outdir}/secureboot.cer"

openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
    -subj "/CN=Fedora bootc Noctalia Secure Boot/" \
    -keyout "${outdir}/secureboot.key" \
    -out "${outdir}/secureboot.crt"

openssl x509 -in "${outdir}/secureboot.crt" -outform DER \
    -out "${outdir}/secureboot.cer"

chmod 0600 "${outdir}/secureboot.key"
chmod 0644 "${outdir}/secureboot.crt" "${outdir}/secureboot.cer"

echo "Generated:"
echo "  ${outdir}/secureboot.key (private, keep secret)"
echo "  ${outdir}/secureboot.crt (PEM certificate)"
echo "  ${outdir}/secureboot.cer (DER certificate for mokutil)"
