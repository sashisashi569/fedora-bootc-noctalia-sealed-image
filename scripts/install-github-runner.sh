#!/usr/bin/env bash
# Download and install the read-only GitHub Actions runner payload.
set -euxo pipefail

if [[ "${INSTALL_GITHUB_RUNNER:-1}" != "1" ]]; then
    echo "GitHub Actions runner installation disabled"
    exit 0
fi

: "${RUNNER_VERSION:?RUNNER_VERSION is required}"
: "${RUNNER_SHA256:?RUNNER_SHA256 is required}"

rm -rf /usr/libexec/actions-runner
mkdir -p /usr/libexec/actions-runner

curl -fL --retry 3 --retry-delay 2 \
    -o /tmp/actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

echo "${RUNNER_SHA256}  /tmp/actions-runner.tar.gz" | sha256sum -c -

tar -xzf /tmp/actions-runner.tar.gz -C /usr/libexec/actions-runner
rm -f /tmp/actions-runner.tar.gz

# Debug symbols are not needed at runtime.
find /usr/libexec/actions-runner -type f -name '*.pdb' -delete

chown -R root:root /usr/libexec/actions-runner
chmod -R go-w /usr/libexec/actions-runner
