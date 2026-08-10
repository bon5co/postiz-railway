#!/bin/bash
# Elasticsearch for Temporal's visibility store, on Railway.
#
# Two Railway-specific fixes:
#
#   1. Heap sized from the container's own cgroup limit instead of a fixed
#      -Xmx. Upstream's compose file and every competing listing bake
#      `-Xms256m -Xmx256m`, which is a fixed ceiling no matter which plan the
#      deployer is on; ES itself only auto-sizes when ES_JAVA_OPTS does not
#      pin the heap.
#   2. Bind on IPv6. Railway's private network is IPv6-only, so an
#      `0.0.0.0`-only listener is unreachable from Temporal over
#      RAILWAY_PRIVATE_DOMAIN.
set -euo pipefail

log() { echo "[railway-entrypoint] $*"; }

if [ -z "${ES_JAVA_OPTS:-}" ]; then
    limit_bytes=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        limit_bytes="$(cat /sys/fs/cgroup/memory.max)"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        limit_bytes="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    fi
    case "$limit_bytes" in
        ''|max|*[!0-9]*) mib=1024 ;;
        *) mib=$((limit_bytes / 1048576)) ;;
    esac
    # Anything above ~64 GiB is the host's memory leaking through, not a quota.
    [ "$mib" -gt 65536 ] && mib=1024
    heap=$((mib / 2))
    [ "$heap" -lt 256 ] && heap=256
    # ES must stay below the compressed-oops threshold.
    [ "$heap" -gt 26624 ] && heap=26624
    export ES_JAVA_OPTS="-Xms${heap}m -Xmx${heap}m"
    log "container memory ${mib}MiB -> ES_JAVA_OPTS=${ES_JAVA_OPTS}"
else
    log "ES_JAVA_OPTS provided by the environment: ${ES_JAVA_OPTS}"
fi

# The volume arrives owned by uid 0 and Elasticsearch runs as uid 1000. The
# stock entrypoint repairs it when TAKE_FILE_OWNERSHIP is set, which the image
# ENV does, so nothing to do here beyond saying what the mount looks like.
log "data dir owner=$(stat -c %u:%g /usr/share/elasticsearch/data)"

exec /bin/tini -- /usr/local/bin/docker-entrypoint.sh eswrapper
