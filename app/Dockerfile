# Postiz for Railway.
#
# Pinned by digest as well as tag: Postiz runs `prisma db push
# --accept-data-loss` on every boot, which is forward-only in effect, so a
# `latest` deploy is an unrequested one-way schema change.
FROM ghcr.io/gitroomhq/postiz-app:v2.25.1@sha256:d2b37802e96757729fdea2d3d71287f841c2b619faa1cb4c21dac07df657fde1

# curl for the in-container seed calls, gettext-base for envsubst (the stock
# nginx.conf has a hardcoded listen port and no templating of any kind).
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Baked, NOT published as template variables: templateGenerate drops a variable
# whose default is a LITERAL, so anything shipped that way reaches the deploy
# form as a blank REQUIRED field. Only values that genuinely belong to the
# deployer stay variables, and those are Railway expressions, whose defaults do
# survive.
#
# NOT_SECURED is deliberately absent — it is a truthiness check, so even
# "false" strips secure/httpOnly/sameSite from the auth cookie.
# NEXT_PUBLIC_UPLOAD_DIRECTORY is deliberately absent too: it is read nowhere in
# the source tree (upstream's own compose file sets it; the code reads
# NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY).
ENV IS_GENERAL=true \
    DISABLE_REGISTRATION=true \
    STORAGE_PROVIDER=local \
    UPLOAD_DIRECTORY=/uploads \
    BACKEND_INTERNAL_URL=http://localhost:3000 \
    ORCHESTRATOR_PORT=3002 \
    TEMPORAL_NAMESPACE=default \
    API_LIMIT=30 \
    NX_ADD_PLUGINS=false \
    POSTIZ_ADMIN_EMAIL=admin@postiz.local \
    POSTIZ_ORG_NAME="My Workspace" \
    POSTIZ_AUTH_RATE=10r/m \
    POSTIZ_AUTH_BURST=5 \
    POSTIZ_MAX_BODY_SIZE=2G

# The boot script runs `pnpm dlx prisma@6.5.0 db push`, i.e. it fetches Prisma
# from the npm registry on EVERY boot. Warm the store at build time so a slow or
# unreachable registry cannot stall a deploy.
RUN pnpm dlx prisma@6.5.0 --version || echo "prisma warm-up skipped"

COPY nginx.conf.template /etc/postiz/nginx.conf.template
COPY proxy-headers.conf /etc/postiz/proxy-headers.conf
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# Railway's HTTP healthcheck dials the INJECTED port, so the gateway must honour
# $PORT (the entrypoint renders it into nginx.conf) and the template's
# target_port must be 8080.
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
