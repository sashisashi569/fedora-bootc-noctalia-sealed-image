#!/usr/bin/env bash
# Run a local OCI registry for testing the sealed bootc image.
#
# The registry is an HTTP registry bound to BIND_ADDR (default 127.0.0.1)
# and is intended for local testing only. Image data is kept in
# ./.local-registry by default (override with DATA=...).
#
# Usage:
#   ./scripts/local-registry.sh start
#   BIND_ADDR=192.168.122.1 ./scripts/local-registry.sh start
#   ./scripts/local-registry.sh push localhost/fedora-bootc-noctalia-sealed:latest noctalia-sealed:test
#   ./scripts/local-registry.sh list
#   ./scripts/local-registry.sh stop
#
# Environment:
#   PORT           Host port (default: 5000)
#   NAME           Container name (default: noctalia-local-registry)
#   DATA           Registry data directory (default: ./.local-registry)
#   PODMAN         Podman binary (default: podman)
#   REGISTRY_IMAGE Registry container image (default: docker.io/library/registry:2)
set -euo pipefail

PORT="${PORT:-5000}"
NAME="${NAME:-noctalia-local-registry}"
DATA="${DATA:-${PWD}/.local-registry}"
PODMAN="${PODMAN:-podman}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-docker.io/library/registry:2}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"

if [[ "${BIND_ADDR}" == "127.0.0.1" || "${BIND_ADDR}" == "0.0.0.0" || "${BIND_ADDR}" == "::" ]]; then
    DEFAULT_ADDR="localhost:${PORT}"
else
    DEFAULT_ADDR="${BIND_ADDR}:${PORT}"
fi
REGISTRY_ADDR="${REGISTRY_ADDR:-${DEFAULT_ADDR}}"
CHECK_ADDR="${CHECK_ADDR:-${DEFAULT_ADDR}}"

usage() {
    cat <<'EOF'
Usage: local-registry.sh COMMAND

Commands:
  start                 Start the local registry (HTTP, BIND_ADDR)
  stop                  Stop and remove the registry container
  status                Show container status and HTTP API status
  logs [-f]             Show registry logs
  push IMAGE [TARGET]   Tag and push a local image into the registry
                        TARGET defaults to <image-name>:<tag>
                        (e.g. noctalia-sealed:test)
  list                  List repositories and tags via the registry API
  reset                 Remove the container and all registry data
  help                  Show this help

Environment:
  PORT                   Host port (default: 5000)
  NAME                   Container name (default: noctalia-local-registry)
  DATA                   Data directory (default: ./.local-registry)
  PODMAN                 Podman binary (default: podman)
  REGISTRY_IMAGE         Registry image (default: docker.io/library/registry:2)
  BIND_ADDR              Address to bind the registry to (default: 127.0.0.1)
                         Use 192.168.122.1 for the libvirt default network.
  REGISTRY_ADDR          Address used in printed refs (default: derived from BIND_ADDR)
  CHECK_ADDR             Address used for HTTP API checks (default: derived from BIND_ADDR)

Examples:
  ./scripts/local-registry.sh start
  BIND_ADDR=192.168.122.1 ./scripts/local-registry.sh start
  ./scripts/local-registry.sh push localhost/fedora-bootc-noctalia-sealed:latest noctalia-sealed:test
  sudo ./scripts/install-sealed.sh --insecure-registry \
    --image localhost:5000/noctalia-sealed:test \
    --disk /dev/nvme0n1 --mok-cert keys/secureboot.cer
  # From a VM on the libvirt default network:
  sudo ./scripts/install-sealed.sh --insecure-registry \
    --image 192.168.122.1:5000/noctalia-sealed:test \
    --disk /dev/vda --mok-cert secureboot.cer
  ./scripts/local-registry.sh list
  ./scripts/local-registry.sh stop
EOF
}

require_tools() {
    command -v "${PODMAN}" >/dev/null || {
        echo "error: ${PODMAN} is required" >&2
        exit 1
    }
    command -v curl >/dev/null || {
        echo "error: curl is required" >&2
        exit 1
    }
}

api_ok() {
    curl -fsS --max-time 2 "http://${CHECK_ADDR}/v2/" >/dev/null 2>&1
}

container_running() {
    "${PODMAN}" container exists "${NAME}" 2>/dev/null || return 1
    [[ "$("${PODMAN}" inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null)" == "true" ]]
}

wait_for_api() {
    for _ in $(seq 1 40); do
        if api_ok; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

start_registry() {
    require_tools
    mkdir -p "${DATA}"
    DATA="$(cd "${DATA}" && pwd)"

    if container_running; then
        echo "Registry container '${NAME}' is already running."
    else
        if "${PODMAN}" container exists "${NAME}" >/dev/null 2>&1; then
            "${PODMAN}" rm -f "${NAME}" >/dev/null 2>&1 || true
        fi
        echo "Starting ${REGISTRY_IMAGE} on ${BIND_ADDR}:${PORT} ..."
        "${PODMAN}" run -d --rm --name "${NAME}" \
            -p "${BIND_ADDR}:${PORT}:5000" \
            -v "${DATA}:/var/lib/registry:z" \
            "${REGISTRY_IMAGE}" >/dev/null
    fi

    if ! wait_for_api; then
        echo "error: registry did not become ready on 127.0.0.1:${PORT}" >&2
        "${PODMAN}" logs "${NAME}" 2>&1 | tail -50 >&2 || true
        exit 1
    fi

    echo "Registry: http://${REGISTRY_ADDR}/v2/"
    echo "Bind:     ${BIND_ADDR}:${PORT}"
    echo "Data:     ${DATA}"
}

stop_registry() {
    require_tools
    "${PODMAN}" stop "${NAME}" >/dev/null 2>&1 || true
    "${PODMAN}" rm -f "${NAME}" >/dev/null 2>&1 || true
    echo "Stopped '${NAME}'."
}

ensure_registry() {
    require_tools
    if ! api_ok; then
        echo "error: registry is not reachable on 127.0.0.1:${PORT}" >&2
        echo "Run '$0 start' first." >&2
        exit 1
    fi
}

default_target() {
    local ref=${1%%@*}
    local name=${ref##*/}
    local tag=latest
    if [[ "${name}" == *:* ]]; then
        tag=${name##*:}
        name=${name%:*}
    fi
    printf '%s:%s' "${name,,}" "${tag,,}"
}

push_image() {
    local src=${1-}
    local target=${2-}
    if [[ -z "${src}" ]]; then
        echo "error: push requires an image reference" >&2
        usage >&2
        exit 1
    fi
    ensure_registry

    if ! "${PODMAN}" image exists "${src}" >/dev/null 2>&1; then
        echo "error: local image '${src}' does not exist" >&2
        exit 1
    fi

    if [[ -z "${target}" ]]; then
        target="$(default_target "${src}")"
    fi
    target=${target#localhost:"${PORT}"/}
    target=${target#"${REGISTRY_ADDR}"/}
    target=${target,,}
    [[ "${target}" == *:* ]] || target="${target}:latest"

    local full="${REGISTRY_ADDR}/${target}"
    echo "Tagging ${src} -> ${full}"
    "${PODMAN}" tag "${src}" "${full}"
    echo "Pushing ${full} ..."
    "${PODMAN}" push --tls-verify=false "${full}"

    cat <<EOF

Pushed: ${full}

Install it with:
  sudo ./scripts/install-sealed.sh --insecure-registry \\
    --image ${full} \\
    --disk /dev/nvme0n1 \\
    --mok-cert keys/secureboot.cer
EOF
}

list_registry() {
    ensure_registry
    local catalog
    catalog="$(curl -fsS "http://${CHECK_ADDR}/v2/_catalog")"
    if ! command -v jq >/dev/null 2>&1; then
        echo "${catalog}"
        echo "Install jq for a formatted repository/tag listing." >&2
        return 0
    fi
    local repo
    for repo in $(printf '%s' "${catalog}" | jq -r '.repositories[]?'); do
        echo "${repo}:"
        curl -fsS "http://${CHECK_ADDR}/v2/${repo}/tags/list" |
            jq -r '.tags[]? // empty' | sed 's/^/  /'
    done
}

status_registry() {
    require_tools
    if "${PODMAN}" container exists "${NAME}" >/dev/null 2>&1; then
        "${PODMAN}" ps --filter "name=^${NAME}$" \
            --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    else
        echo "Container '${NAME}' does not exist."
    fi
    if api_ok; then
        echo "HTTP API: http://${REGISTRY_ADDR}/v2/ (OK)"
    else
        echo "HTTP API: unreachable"
    fi
}

reset_registry() {
    require_tools
    local answer
    read -r -p "Delete registry data in '${DATA}'? [y/N] " answer
    if [[ ! "${answer}" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    stop_registry
    rm -rf "${DATA}"
    echo "Removed ${DATA}."
}

main() {
    local cmd=${1-}
    case "${cmd}" in
        start) start_registry ;;
        stop) stop_registry ;;
        status) status_registry ;;
        logs) shift; require_tools; "${PODMAN}" logs "$@" "${NAME}" ;;
        push) shift; push_image "$@" ;;
        list) list_registry ;;
        reset) reset_registry ;;
        help|-h|--help|"") usage ;;
        *)
            echo "error: unknown command '${cmd}'" >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
