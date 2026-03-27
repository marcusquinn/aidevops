---
description: Package custom applications for Cloudron deployment
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Cloudron App Packaging Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Docs**: [docs.cloudron.io/packaging](https://docs.cloudron.io/packaging/tutorial/) | [CLI Reference](https://docs.cloudron.io/packaging/cli/) | [Publishing](https://docs.cloudron.io/packaging/publishing/)
- **Source Code**: [git.cloudron.io/packages](https://git.cloudron.io/packages) (200+ official app packages) | [By Technology](https://git.cloudron.io/explore/projects/topics)
- **Forum**: [forum.cloudron.io/category/96](https://forum.cloudron.io/category/96/app-packaging-development)
- **Base Image Tags**: https://hub.docker.com/r/cloudron/base/tags
- **Sub-docs**: [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md) | [manifest-ref.md](cloudron-app-packaging-skill/manifest-ref.md) | [cloudron-git-reference.md](cloudron-git-reference.md)

**Golden Rules** (violations cause package failure):

1. `/app/code` READ-ONLY at runtime — write to `/app/data`
2. Run as `cloudron` user (UID 1000): `exec gosu cloudron:cloudron`
3. Use Cloudron addons (mysql, postgresql, redis) — never bundle databases
4. Disable built-in auto-updaters — Cloudron manages updates via image replacement
5. App receives HTTP — Cloudron's nginx terminates SSL

**File Structure**: `CloudronManifest.json`, `Dockerfile`, `start.sh`, `logo.png` (256x256).

**CLI Workflow**:

```bash
npm install -g cloudron
cloudron login my.cloudron.example && cloudron init
cloudron build && cloudron install --location testapp
cloudron build && cloudron update --app testapp  # iterate
cloudron logs -f --app testapp
cloudron exec --app testapp   # shell into container
cloudron debug --app testapp  # pause app, writable fs
```

<!-- AI-CONTEXT-END -->

## Pre-Packaging Assessment

Score both axes before writing code. Initial packaging is ~25% of effort; SSO integration, upgrade testing, backup correctness, and maintenance are the remaining 75%. Structural 10+ or compliance 9+ → recommend against packaging.

**Axis A: Structural Difficulty**

| Sub-axis | 0 (Easy) | 1 (Moderate) | 2-3 (Hard) |
|----------|----------|--------------|------------|
| A1. Process count | Single process | 2-4 processes | 5+ or separate containers |
| A2. Data storage | Cloudron addon or SQLite | — | Exotic store (Elasticsearch, S3) |
| A3. Runtime | Node.js, Python, PHP (in base) | Go, Java, Ruby, Rust (binary) | Must compile from source |
| A4. Message broker | None needed | Redis works (Celery/Bull) | Needs AMQP (LavinMQ) |
| A5. Filesystem writes | 0-3 symlinks | 4-8 symlinks | 9+ or needs source patching |
| A6. Authentication | Native LDAP/OIDC or no auth | Own auth, scriptable | Mandatory browser setup wizard |

**Structural subtotal** (max 14): 0-2 Trivial · 3-4 Easy · 5-6 Medium · 7-9 Hard · 10+ Impractical.

**Axis B: Compliance & Maintenance Cost**

| Sub-axis | 0 (Low) | 1-2 (Moderate) | 3 (High) |
|----------|---------|----------------|----------|
| B1. SSO quality | Native LDAP/OIDC works | Partial SSO or proxyauth only | Auth conflicts with Cloudron (e.g., GoTrue) |
| B2. Upstream stability | Stable, semantic versioning | Occasional breaking changes | Pre-release, frequent breaks, licensing risk |
| B3. Backup complexity | Cloudron-managed DB + /app/data | SQLite or custom backup | Internal stores needing snapshot APIs |
| B4. Platform fit | Standard HTTP behind reverse proxy | WebSocket (needs nginx config) | Raw TCP/UDP or horizontal scaling assumed |
| B5. Config drift | Env vars, no self-modification | Plugin/extension system at runtime | Self-updating, modifies own code |

**Compliance subtotal** (max 13): 0-2 Low · 3-5 Moderate · 6-8 High · 9+ Very High.

### Pre-Packaging Research

1. Fetch upstream `docker-compose.yml` — **most valuable artifact** (reveals true dependency graph), `Dockerfile`, dependency files, auth docs (search "LDAP", "OIDC", "SSO"), releases page.
2. **Forum search**: `https://forum.cloudron.io/search?term=APP_NAME&in=titles`
3. **App store**: `cloudron appstore search APP_NAME`
4. **Reference apps**: [cloudron-git-reference.md](cloudron-git-reference.md) for apps by technology.

## Base Image Selection

**Always start from `cloudron/base:5.0.0`.** Never start from the upstream app's Docker image — monolithic upstream images bundle databases, reverse proxies, and init systems that conflict with Cloudron's assumptions (e.g., docassemble: 25 symlinks, 15-20 min boot times). Read the upstream `docker-compose.yml` to understand dependencies, then install the app on `cloudron/base` via its package manager.

**Multi-stage builds**: Only when the build toolchain is exotic or compilation on `cloudron/base` is impractical. Build in the upstream image, `COPY --from` artifacts into a final `cloudron/base` stage.

**Alpine/musl warning**: Binaries compiled in Alpine (musl libc) will NOT run on `cloudron/base` (Ubuntu/glibc). Always compile in a glibc-based builder stage.

**Base image contents (Cloudron 9.1.3)**:

| Component | Version |
|-----------|---------|
| Ubuntu | 24.04.1 LTS |
| Node.js | 24.x (default PATH); Node 22 LTS at `/usr/local/node-22.14.0` |
| Python | 3.12.3 (pip 24.0) |
| PHP | 8.3.6 (extensions: redis, imagick, ldap, gd, mbstring, etc.) |
| Nginx / Apache | 1.24.0 / 2.4.58 |
| Supervisor / gosu | 4.2.5 / 1.17 |
| gcc/g++ / ImageMagick / ffmpeg | 13.3.0 / 6.9.12 / 6.1.1 |
| psql / mysql / redis-cli / mongosh | 16.6 / 8.0.41 / 7.4.2 / 2.4.0 |

**NOT in base image** (install if needed): Ruby, Go, Java, Rust, pandoc, wkhtmltopdf.

## CloudronManifest.json

Full field reference: [manifest-ref.md](cloudron-app-packaging-skill/manifest-ref.md). Addon options and env vars: [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md).

**Key patterns**: Read env vars fresh on every start (values can change across restarts). Run DB migrations on each start. `localstorage` is MANDATORY for persistent data. Health check path must return HTTP 200 unauthenticated.

**Memory limits** (`memoryLimit` in bytes: 256MB=268435456, 512MB=536870912, 1GB=1073741824):

| App Type | Recommended |
|----------|-------------|
| Static/Simple PHP | 128-256 MB |
| Node.js/Go/Rust | 256-512 MB |
| PHP with workers / Python/Ruby | 512-768 MB |
| Java/JVM | 1024+ MB |

**Dynamic worker count from memory limit**:

```bash
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    mem=$(cat /sys/fs/cgroup/memory.max)
    [[ "$mem" == "max" ]] && mem=$((2 * 1024 * 1024 * 1024))
else
    mem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
workers=$(( mem / 1024 / 1024 / 128 ))  # 1 worker per 128MB
[[ $workers -lt 1 ]] && workers=1
```

**TCP/UDP ports**: Declare in `tcpPorts` manifest field; exposed as env vars (e.g., `XMPP_C2S_PORT`). Apps handle their own TLS termination.

**9.1+ features**: `persistentDirs` (persist dirs without `localstorage`), `backupCommand`/`restoreCommand` (custom backup), SQLite backup: `"localstorage": { "sqlite": { "paths": ["/app/data/db/app.db"] } }`.

**General Variables**: `CLOUDRON_APP_ORIGIN` (full URL), `CLOUDRON_APP_DOMAIN` (domain only), `CLOUDRON=1`.

## Dockerfile Patterns

```dockerfile
FROM cloudron/base:5.0.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx php8.2-fpm php8.2-mysql \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/code
COPY --chown=cloudron:cloudron . /app/code/

# Preserve defaults for first-run initialization
RUN mkdir -p /app/code/defaults && \
    mv /app/code/config /app/code/defaults/config 2>/dev/null || true && \
    mv /app/code/storage /app/code/defaults/storage 2>/dev/null || true

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh
EXPOSE 8000
CMD ["/app/code/start.sh"]
```

**PHP**: Redirect temp paths to `/run`: `RUN rm -rf /var/lib/php/sessions && ln -s /run/php/sessions /var/lib/php/sessions`. PHP-FPM pool: `php_value[session.save_path] = /run/php/sessions`. In start.sh: `mkdir -p /run/php/sessions /run/php/uploads /run/php/tmp`.

**Node.js**: `RUN npm ci --production && npm cache clean --force` + `ENV NODE_ENV=production`. Keep `node_modules` in `/app/code`.

**Python**: `ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1` + `RUN pip install --no-cache-dir -r requirements.txt`.

**nginx** — MANDATORY writable temp paths (nginx fails to start without these):

```nginx
client_body_temp_path /run/nginx/client_body;
proxy_temp_path /run/nginx/proxy;
fastcgi_temp_path /run/nginx/fastcgi;
server {
    listen 8000;
    root /app/code/public;
    location / { try_files $uri $uri/ /index.php?$query_string; }
}
```

In start.sh: `mkdir -p /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi`

**Apache**:

```dockerfile
RUN rm /etc/apache2/sites-enabled/* \
    && sed -e 's,^ErrorLog.*,ErrorLog "/dev/stderr",' -i /etc/apache2/apache2.conf \
    && sed -e "s,MaxSpareServers[^:].*,MaxSpareServers 5," -i /etc/apache2/mods-available/mpm_prefork.conf \
    && a2disconf other-vhosts-access-log \
    && echo "Listen 8000" > /etc/apache2/ports.conf
```

## start.sh Architecture

Single-process: `exec gosu cloudron:cloudron <cmd>` directly. Multi-process: supervisord. Web servers managing own children (Apache, nginx): direct exec.

```bash
#!/bin/bash
set -eu
FIRST_RUN=false; [[ ! -f /app/data/.initialized ]] && FIRST_RUN=true

mkdir -p /app/data/config /app/data/storage /app/data/logs /run/app /run/php /run/nginx
ln -sfn /app/data/config /app/code/config
ln -sfn /app/data/storage /app/code/storage
ln -sfn /app/data/logs /app/code/logs

[[ "$FIRST_RUN" == "true" ]] && cp -rn /app/code/defaults/config/* /app/data/config/ 2>/dev/null || true

# Config injection (choose one):
# A: envsubst < /app/code/config.template > /app/data/config/app.conf
# B: sed -i "s|APP_URL=.*|APP_URL=${CLOUDRON_APP_ORIGIN}|" /app/data/config/.env

sed -i "s|'auto_update' => true|'auto_update' => false|" /app/data/config/settings.php 2>/dev/null || true
gosu cloudron:cloudron /app/code/bin/migrate --force
chown -R cloudron:cloudron /app/data /run/app
touch /app/data/.initialized
exec gosu cloudron:cloudron node /app/code/server.js
```

**Multi-process supervisord.conf** (repeat `[program:*]` for each process):

```ini
[supervisord]
nodaemon=true
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:web]
command=/app/code/bin/web-server
directory=/app/code
user=cloudron
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

End of start.sh: `exec /usr/bin/supervisord --configuration /app/code/supervisord.conf`

## Message Broker

No AMQP addon in Cloudron. Two options:

**Option A: Redis (preferred)** — if the app supports Redis as broker (Celery does natively):

```python
CELERY_BROKER_URL = os.environ['CLOUDRON_REDIS_URL']
CELERY_RESULT_BACKEND = os.environ['CLOUDRON_REDIS_URL']
```

**Option B: LavinMQ** — lightweight AMQP (~40 MB RAM, drop-in RabbitMQ replacement). Store data under `/app/data/lavinmq`, run as a Supervisor program:

```dockerfile
RUN curl -fsSL https://packagecloud.io/cloudamqp/lavinmq/gpgkey | gpg --dearmor -o /usr/share/keyrings/lavinmq.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/lavinmq.gpg] https://packagecloud.io/cloudamqp/lavinmq/ubuntu/ noble main" \
    > /etc/apt/sources.list.d/lavinmq.list && \
    apt-get update && apt-get install -y lavinmq && rm -rf /var/cache/apt /var/lib/apt/lists/*
```

## Common Anti-Patterns

| Anti-pattern | Wrong | Correct |
|---|---|---|
| Starting from upstream image | `FROM someapp/monolith:latest` | `FROM cloudron/base:5.0.0` + install app |
| Writing to /app/code | Write to `/app/code/cache/` | Write to `/app/data/cache/` |
| Running as root | `node /app/code/server.js` | `exec gosu cloudron:cloudron node /app/code/server.js` |
| Missing exec | `gosu cloudron:cloudron node server.js` | `exec gosu cloudron:cloudron node server.js` |
| Non-idempotent start.sh | `cp config.json /app/data/` | `cp -n config.json /app/data/ 2>/dev/null \|\| true` |
| Hardcoded URLs | `"https://myapp.example.com"` | `process.env.CLOUDRON_APP_ORIGIN` |
| Bundling databases | `apt-get install -y postgresql` | Use Cloudron addons |
| Caching env vars | Store `process.env.CLOUDRON_MYSQL_HOST` at startup | Read fresh each time |

## Upgrade & Migration Handling

Track version in `/app/data/.app_version`; compare on start to run per-version migration blocks. Migrations MUST be idempotent — use framework migration tracking (Laravel, Django, Rails) or raw SQL with `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| App won't start | `cloudron logs --app testapp` / `cloudron debug --app testapp` |
| Permission denied | `chown -R cloudron:cloudron /app/data` — check for writes to `/app/code` |
| DB connection fails | Verify addon in manifest; `cloudron exec --app testapp` → `env \| grep CLOUDRON` |
| Health check fails | `curl -v http://localhost:8000/health` — verify app listens on httpPort |
| Memory exceeded | Increase `memoryLimit`; check for leaks; optimize worker counts |

## Validation Checklist

```text
[ ] Fresh install + restart (cloudron restart --app) succeed
[ ] Health check returns 200
[ ] File uploads persist across restarts
[ ] Database connections work; email works (if applicable)
[ ] Memory stays within limit
[ ] Upgrade from previous version works
[ ] Backup/restore cycle works
[ ] Auto-updater disabled; logs stream to stdout/stderr
```

## Publishing

Fork https://git.cloudron.io/cloudron/appstore, add your app directory with manifest and icon, submit a merge request. See: https://docs.cloudron.io/packaging/publishing/
