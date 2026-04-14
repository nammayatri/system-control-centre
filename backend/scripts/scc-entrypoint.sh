#!/bin/sh
# System Control Centre — container entrypoint.
#
# Resolution order for the dhall config:
#   1. DHALL_CONFIGS env var (base64-encoded dhall body)  ← prod / k8s
#      Decode it and point the binary at the resulting file.
#   2. Else: leave SC_CONFIG_PATH alone (or unset)        ← local dev
#      The binary uses its built-in default (./dhall-configs/system-control.dhall)
#      or whatever SC_CONFIG_PATH was already set to by the caller.
#
# This lets the same image run:
#   • Locally with `docker run -v /path/to/dhall-configs:/srv/scc/dhall-configs scc-backend`
#   • In k8s with `env: [{ name: DHALL_CONFIGS, valueFrom: { secretKeyRef: ... } }]`
#
# Falls through to `exec scc "$@"` so signals + tini work correctly.

set -eu

if [ -n "${DHALL_CONFIGS:-}" ]; then
    mkdir -p /tmp/scc
    echo "$DHALL_CONFIGS" | base64 -d > /tmp/scc/system-control.dhall
    export SC_CONFIG_PATH=/tmp/scc/system-control.dhall
    echo "[entrypoint] decoded DHALL_CONFIGS → $SC_CONFIG_PATH"
fi

exec /usr/local/bin/scc "$@"
