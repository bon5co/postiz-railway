# Temporal server for Postiz, on Railway.
#
# Pinned to 1.28.1, the version Postiz's own compose file pins. Every competing
# listing runs `temporalio/auto-setup` with no tag at all, which Temporal's docs
# label a development-only image and which floats across schema versions.
FROM temporalio/auto-setup:1.28.1

USER root
COPY dynamicconfig.yaml /etc/temporal/config/dynamicconfig/railway.yaml
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh \
    && chown temporal /etc/temporal/config/dynamicconfig/railway.yaml
USER temporal

# Baked, not published as template variables. Only POSTGRES_SEEDS/POSTGRES_PWD/
# ES_SEEDS stay variables, and they are Railway expressions, whose defaults
# survive templateGenerate.
ENV DB=postgres12 \
    DB_PORT=5432 \
    POSTGRES_USER=postgres \
    ENABLE_ES=true \
    ES_VERSION=v7 \
    ES_SCHEME=http \
    ES_PORT=9200 \
    TEMPORAL_NAMESPACE=default \
    DYNAMIC_CONFIG_FILE_PATH=config/dynamicconfig/railway.yaml \
    SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES=true

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
