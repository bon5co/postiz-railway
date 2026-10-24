# postiz-railway

Wrapper images behind the Railway template for [Postiz](https://github.com/gitroomhq/postiz-app)
v2.25.3 — the open-source social media scheduler (Buffer alternative).

Three images, all thin wrappers over pinned upstream tags:

| image | base | what the wrapper adds |
| --- | --- | --- |
| `ghcr.io/bon5co/postiz-railway:2.25.3` | `ghcr.io/gitroomhq/postiz-app:v2.25.3` | moves nginx onto Railway's injected `$PORT` and pins the backend back to 3000; refuses to boot without an admin password; seeds the organization + SUPERADMIN through upstream's own `/auth/register` handler on loopback **before** nginx serves; throttles the auth routes keyed on the first `X-Forwarded-For` address |
| `ghcr.io/bon5co/postiz-railway-elasticsearch:7.17.27` | `elasticsearch:7.17.27` | JVM heap sized from `/sys/fs/cgroup/memory.max` instead of a fixed `-Xmx512m`; binds IPv6 (Railway private networking); `TAKE_FILE_OWNERSHIP` for the root-owned volume |
| `ghcr.io/bon5co/postiz-railway-temporal:1.28.1` | `temporalio/auto-setup:1.28.1` | pinned instead of untagged; the dynamic-config file Postiz's compose bind-mounts, baked in; ringpop bound/broadcast on the container's private IPv6 |

## Why each fix exists

**The `$PORT` trap.** Upstream's `/etc/nginx/nginx.conf` has a hardcoded `listen 5000;` and no
templating; the frontend is `next start -p 4200`; the backend is `process.env.PORT || 3000`.
Railway injects `PORT`, so on the stock image the backend answers on the edge port while nginx
sits unreachable on 5000. Measured on `v2.25.3` with `PORT=8080`: `GET /` returns
`App is running!` (the backend, not the UI), `GET /api/` returns `404 Cannot GET /api/`, and
`GET /uploads/<file>` returns 404 — while any healthcheck on `/` reads a clean 200. The wrapper
renders `listen $PORT` at boot and exports `PORT=3000` before starting pm2.

**Anonymous claimability.** `canRegister()` returns true unconditionally unless
`DISABLE_REGISTRATION=true`, and even then only while the organization count is 0. So the admin
must exist before the public port ever answers — the wrapper seeds it while nginx is still down,
then verifies the login and logs the result.

**No login throttle.** Upstream applies none: 20 wrong passwords answer `400` twenty times
(measured against the backend directly). The gateway adds `limit_req` keyed on the FIRST address
of `X-Forwarded-For`, because Railway's edge hop rotates per request and `$remote_addr` is always
the edge.

Images are built and pushed by `.github/workflows/build.yml`.
