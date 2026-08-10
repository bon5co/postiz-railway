# Elasticsearch 7 as Temporal's visibility store, for Railway.
#
# v7 because that is what Temporal's own auto-setup schema targets with
# ES_VERSION=v7, which is what Postiz's compose file uses.
FROM elasticsearch:7.17.27

# Baked, not published as template variables (a literal default publishes as a
# blank required field). `network.host` is the IPv6 wildcard because Railway's private
# network is IPv6-only. Security stays off: this service has NO public domain
# and is only reachable from its own project's private network.
ENV discovery.type=single-node \
    xpack.security.enabled=false \
    network.host=:: \
    cluster.routing.allocation.disk.threshold_enabled=true \
    cluster.routing.allocation.disk.watermark.low=512mb \
    cluster.routing.allocation.disk.watermark.high=256mb \
    cluster.routing.allocation.disk.watermark.flood_stage=128mb \
    TAKE_FILE_OWNERSHIP=1

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
