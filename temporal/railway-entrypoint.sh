#!/bin/bash
# Temporal server (auto-setup) on Railway.
#
# Railway's private network is IPv6-only, so the default
# `BIND_ON_IP=$(getent hosts $(hostname))` either resolves to nothing usable or
# binds an address Postiz cannot dial from a sibling service. The server is bound
# on :: and ringpop is given this container's real private IPv6 address to
# broadcast.
set -euo pipefail

log() { echo "[railway-entrypoint] $*"; }

if [ -z "${TEMPORAL_BROADCAST_ADDRESS:-}" ]; then
    addr=""
    if [ -n "${RAILWAY_PRIVATE_DOMAIN:-}" ]; then
        addr="$(getent ahostsv6 "$RAILWAY_PRIVATE_DOMAIN" 2>/dev/null | awk '/STREAM/{print $1; exit}')"
    fi
    [ -n "$addr" ] || addr="$(hostname -i 2>/dev/null | tr ' ' '\n' | grep ':' | head -1 || true)"
    [ -n "$addr" ] || addr="127.0.0.1"
    export TEMPORAL_BROADCAST_ADDRESS="$addr"
fi
export BIND_ON_IP="${BIND_ON_IP:-::}"

# TEMPORAL_ADDRESS is used ONLY by the CLI that auto-setup.sh polls for
# readiness and then creates the default namespace with — the server itself
# takes BIND_ON_IP. Left unset, upstream's entrypoint derives it from
# BIND_ON_IP, which with an IPv6 wildcard produces the literal `[::]:7233`.
# That address is not dialable, so the server serves normally
# ("Starting to serve on frontend listener") while auto-setup loops
# `failed reaching server: Frontend is not healthy yet` forever and the
# default namespace is never created. Point the CLI at loopback instead.
export TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-127.0.0.1:7233}"
export TEMPORAL_CLI_ADDRESS="$TEMPORAL_ADDRESS"
log "BIND_ON_IP=$BIND_ON_IP broadcast=$TEMPORAL_BROADCAST_ADDRESS cli=$TEMPORAL_ADDRESS es=${ES_SEEDS:-<unset>} db=${POSTGRES_SEEDS:-<unset>}"

exec /etc/temporal/entrypoint.sh autosetup
