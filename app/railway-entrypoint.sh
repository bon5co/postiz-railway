#!/usr/bin/env bash
# Postiz on Railway.
#
# Five things happen here that the stock image cannot do for itself. In order,
# and all of them BEFORE nginx ever answers the public port:
#
#   1. Move nginx off its hardcoded `listen 5000;` onto the port Railway
#      injected, and pin the backend back to 3000. Upstream bakes
#      `listen 5000;` into /etc/nginx/nginx.conf with no envsubst, proxies
#      `/api/` at `localhost:3000`, and the backend does `process.env.PORT ||
#      3000`. Railway injects PORT, so on the stock image the backend moves off
#      3000 while nginx keeps proxying to 3000: the UI loads, every API call
#      502s, and a healthcheck on the injected port hits the BACKEND directly
#      and returns a clean 200. Green, and unusable.
#   2. Refuse to boot without an admin password, instead of publishing an
#      instance the first stranger to find the URL can claim.
#   3. Seed the organization and its SUPERADMIN through upstream's own
#      /auth/register handler on 127.0.0.1, so the bcrypt hash, the org row and
#      the API key are exactly what the app would have made.
#      DISABLE_REGISTRATION=true only closes signup once an organization
#      EXISTS (canRegister() returns `getCount() === 0`), so seeding after the
#      public port is live would leave a real window — the AzuraCast lesson.
#   4. Verify that seeded account can actually log in, and say so in the log.
#   5. Put a login/register throttle in front. Upstream has none anywhere:
#      20 wrong passwords answer 400 x20.
set -euo pipefail

log() { echo "[railway-entrypoint] $*"; }

# --- 0. ports -------------------------------------------------------------
POSTIZ_EDGE_PORT="${PORT:-8080}"
export POSTIZ_EDGE_PORT
export ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-3002}"

# `NOT_SECURED` is a truthiness check (`!process.env.NOT_SECURED`), so even the
# string "false" strips secure/httpOnly/sameSite off the auth cookie and echoes
# the JWT back in a response header. It must be ABSENT, not false.
if [ -n "${NOT_SECURED:-}" ]; then
    log "NOT_SECURED is set to '${NOT_SECURED}'; it is a truthiness check, so ANY value disables secure cookies. Unsetting it."
    unset NOT_SECURED
fi

# --- 1. uploads volume ----------------------------------------------------
UPLOAD_DIRECTORY="${UPLOAD_DIRECTORY:-/uploads}"
export UPLOAD_DIRECTORY
mkdir -p "$UPLOAD_DIRECTORY"
log "uploads dir $UPLOAD_DIRECTORY owner=$(stat -c %u:%g "$UPLOAD_DIRECTORY") (container runs as uid $(id -u))"
if ! touch "$UPLOAD_DIRECTORY/.railway-write-test" 2>/dev/null; then
    log "ERROR: $UPLOAD_DIRECTORY is not writable. Every media upload will fail. Check the volume mount."
    exit 1
fi
rm -f "$UPLOAD_DIRECTORY/.railway-write-test"

# --- 2. gateway config ----------------------------------------------------
export POSTIZ_UPLOAD_LOCATION="${UPLOAD_DIRECTORY%/}/"
export POSTIZ_UPLOAD_ALIAS="${UPLOAD_DIRECTORY%/}/"
envsubst '${POSTIZ_EDGE_PORT} ${POSTIZ_AUTH_RATE} ${POSTIZ_AUTH_BURST} ${POSTIZ_MAX_BODY_SIZE} ${POSTIZ_UPLOAD_LOCATION} ${POSTIZ_UPLOAD_ALIAS}' \
    < /etc/postiz/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t
log "gateway will listen on ${POSTIZ_EDGE_PORT}, auth throttle ${POSTIZ_AUTH_RATE} burst ${POSTIZ_AUTH_BURST}"

# The backend must stay where nginx proxies it. This export is what makes the
# injected PORT harmless; the frontend is `next start -p 4200` and the
# orchestrator reads ORCHESTRATOR_PORT, so neither collides.
export PORT=3000

# --- 3. admin credentials -------------------------------------------------
POSTIZ_ADMIN_EMAIL="${POSTIZ_ADMIN_EMAIL:-admin@postiz.local}"
if [ -z "${POSTIZ_ADMIN_PASSWORD:-}" ]; then
    log "ERROR: POSTIZ_ADMIN_PASSWORD is empty."
    log "       Postiz's canRegister() returns true for everyone until an organization exists,"
    log "       so booting without a seeded admin publishes an instance any visitor can claim."
    log "       Set POSTIZ_ADMIN_PASSWORD and redeploy."
    exit 1
fi
if [ "${#POSTIZ_ADMIN_PASSWORD}" -lt 8 ]; then
    log "ERROR: POSTIZ_ADMIN_PASSWORD must be at least 8 characters."
    exit 1
fi

# --- 4. wait for dependencies --------------------------------------------
# On a template deploy every service starts at once. The backend registers two
# Temporal search attributes during bootstrap and exits if Temporal is not
# there, so without this the first boot always burns a restart cycle.
hostport_of() {
    hp="${1#*://}"; hp="${hp#*@}"; hp="${hp%%/*}"; hp="${hp%%\?*}"
    host="${hp%%:*}"; port="${hp##*:}"
    case "$port" in ''|*[!0-9]*) port="$2" ;; esac
    echo "$host $port"
}
wait_for() {
    name="$1"; url="${2:-}"; default_port="$3"
    [ -n "$url" ] || { log "$name: no address configured, skipping wait"; return 0; }
    read -r host port <<<"$(hostport_of "$url" "$default_port")"
    n=0
    while [ "$n" -lt 90 ]; do
        if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
            log "$name reachable at $host:$port"
            return 0
        fi
        sleep 2; n=$((n + 1))
    done
    log "WARNING: $name still unreachable at $host:$port after 180s, starting anyway"
}
wait_for postgres "${DATABASE_URL:-}" 5432
wait_for redis "${REDIS_URL:-}" 6379
wait_for temporal "${TEMPORAL_ADDRESS:-}" 7233

# --- 5. application stack ------------------------------------------------
# `pnpm run pm2` = pm2 delete all; prisma db push; start the three processes;
# pm2 logs. It stays in the foreground, so it runs in the background here and
# nginx is started only after the admin exists.
cd /app
pnpm run pm2 &
STACK_PID=$!

api() {  # method path json-body
    curl -s -o /tmp/postiz-api.out -w '%{http_code}' -X "$1" \
        "http://127.0.0.1:3000$2" -H 'Content-Type: application/json' \
        --data-binary "${3:-}" || echo 000
}

ready=0
for _ in $(seq 1 180); do
    if ! kill -0 "$STACK_PID" 2>/dev/null; then
        log "ERROR: the application stack exited during startup"
        wait "$STACK_PID" || exit $?
        exit 1
    fi
    if curl -fsS -o /dev/null "http://127.0.0.1:3000/" 2>/dev/null; then
        ready=1; break
    fi
    sleep 2
done
if [ "$ready" = 1 ]; then
    log "backend answering on 127.0.0.1:3000"
else
    log "WARNING: backend did not answer on 127.0.0.1:3000 within 360s"
fi

# Registration ends in a signalWithStart against Temporal, and the orchestrator
# needs ~40s to compile its workflow bundles after the backend already answers.
# Seeding inside that window still creates the organization and the SUPERADMIN,
# but the request returns `400 Failed to signalWithStart Workflow` — a failure
# to read the response by, and not a failure of the seed. So the seed below
# treats the LOGIN as the verdict, and only waits on the orchestrator's
# /health/status (which connects to Temporal and describes the namespace) if it
# has to retry.
wait_for_orchestrator() {
    for _ in $(seq 1 60); do
        if curl -fsS -o /dev/null "http://127.0.0.1:${ORCHESTRATOR_PORT}/health/status" 2>/dev/null; then
            log "orchestrator reports a live Temporal connection"
            return 0
        fi
        sleep 2
    done
    log "WARNING: orchestrator did not report a Temporal connection within 120s"
    return 1
}

# --- 6. seed the organization + admin ------------------------------------
json_escape() { POSTIZ_JSON_IN="$1" node -e 'process.stdout.write(JSON.stringify(process.env.POSTIZ_JSON_IN))'; }

if [ "$ready" = 1 ]; then
    seed_body=$(printf '{"provider":"LOCAL","email":%s,"password":%s,"company":%s}' \
        "$(json_escape "$POSTIZ_ADMIN_EMAIL")" \
        "$(json_escape "$POSTIZ_ADMIN_PASSWORD")" \
        "$(json_escape "${POSTIZ_ORG_NAME:-My Workspace}")")
    lbody=$(printf '{"provider":"LOCAL","email":%s,"password":%s}' \
        "$(json_escape "$POSTIZ_ADMIN_EMAIL")" "$(json_escape "$POSTIZ_ADMIN_PASSWORD")")

    seed_once() {
        can=$(curl -s "http://127.0.0.1:3000/auth/can-register" || echo '')
        if [ "${can#*\"register\":true}" = "$can" ]; then
            log "an organization already exists on this database; leaving it alone"
            return 0
        fi
        code=$(api POST /auth/register "$seed_body")
        case "$code" in
            200|201) log "seeded organization '${POSTIZ_ORG_NAME:-My Workspace}' with SUPERADMIN $POSTIZ_ADMIN_EMAIL" ;;
            *)       log "admin seed returned $code: $(head -c 300 /tmp/postiz-api.out)" ;;
        esac
    }

    seed_once
    lcode=$(api POST /auth/login "$lbody")
    if [ "$lcode" != 200 ]; then
        log "login after the first seed attempt returned $lcode; waiting for the orchestrator and retrying once"
        wait_for_orchestrator || true
        seed_once
        lcode=$(api POST /auth/login "$lbody")
    fi
    if [ "$lcode" = 200 ]; then
        log "verified: $POSTIZ_ADMIN_EMAIL can log in with the current POSTIZ_ADMIN_PASSWORD"
    else
        log "WARNING: login as $POSTIZ_ADMIN_EMAIL returned $lcode ($(head -c 200 /tmp/postiz-api.out))."
        log "         The password is only applied when the organization is first created; change it from the app's settings."
    fi
    # can-register must now be false, i.e. the public port opens closed.
    log "registration open to the public: $(curl -s http://127.0.0.1:3000/auth/can-register)"
fi

# --- 7. gateway ----------------------------------------------------------
nginx
log "gateway up on ${POSTIZ_EDGE_PORT}"

# nginx is a daemon now, so if the app dies the container must die with it —
# otherwise the healthcheck keeps passing against a gateway with nothing behind
# it.
wait "$STACK_PID"
status=$?
log "application stack exited with $status, stopping"
nginx -s stop 2>/dev/null || true
exit "$status"
