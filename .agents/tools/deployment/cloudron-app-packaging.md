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

1. `/app/code` is READ-ONLY at runtime — use `/app/data` for persistent storage
2. Run processes as `cloudron` user (UID 1000) via `exec gosu cloudron:cloudron`
3. Use Cloudron addons (mysql, postgresql, redis) — never bundle databases
4. Disable built-in auto-updaters — Cloudron manages updates via image replacement
5. App receives HTTP (not HTTPS) — Cloudron's nginx terminates SSL

**File Structure**:

```text
my-app/
  CloudronManifest.json    # App metadata and addon requirements
  Dockerfile               # Build instructions (or Dockerfile.cloudron)
  start.sh                 # Runtime entry point
  logo.png                 # 256x256 app icon
```

**CLI Workflow**:

```bash
npm install -g cloudron
cloudron login my.cloudron.example
cloudron init
cloudron build
cloudron install --location testapp
cloudron build && cloudron update --app testapp  # iterate
cloudron logs -f --app testapp
cloudron exec --app testapp                      # shell into container
cloudron debug --app testapp                     # pause app, writable fs
cloudron debug --disable --app testapp
cloudron uninstall --app testapp
```

<!-- AI-CONTEXT-END -->

## Pre-Packaging Assessment

Before writing any code, assess feasibility. Initial packaging is ~25% of total effort; the remaining 75% is SSO integration, upgrade path testing, backup correctness, and ongoing maintenance.

### Step 1: Feasibility Assessment (Two-Axis Scoring)

**Axis A: Structural Difficulty** (how hard to get it running)

| Sub-axis | 0 (Easy) | 1 (Moderate) | 2-3 (Hard) |
|----------|----------|--------------|------------|
| A1. Process count | Single process | 2-4 processes (web + worker) | 5+ processes or requires separate containers |
| A2. Data storage | Cloudron addon or SQLite | — | Needs exotic store (Elasticsearch, Meilisearch, S3/Minio) |
| A3. Runtime | Node.js, Python, PHP (in base image) | Go, Java, Ruby, Rust (binary available) | Must compile from source |
| A4. Message broker | None needed | Redis works as broker (Celery/Bull) | Needs AMQP (requires LavinMQ in container) |
| A5. Filesystem writes | 0-3 symlinks | 4-8 symlinks | 9+ or needs source patching |
| A6. Authentication | Native LDAP/OIDC or no auth | Own auth, scriptable setup | Mandatory browser setup wizard |

**Structural subtotal** (max 14): 0-2 Trivial, 3-4 Easy, 5-6 Medium, 7-9 Hard, 10+ Impractical.

**Axis B: Compliance & Maintenance Cost** (how hard to keep it running well)

| Sub-axis | 0 (Low) | 1-2 (Moderate) | 3 (High) |
|----------|---------|----------------|----------|
| B1. SSO quality | Native LDAP/OIDC works reliably | Partial SSO or proxyauth only | Auth conflicts with Cloudron (e.g., GoTrue coupling) |
| B2. Upstream stability | Stable, semantic versioning | Active with occasional breaking changes | Pre-release, frequent breaking changes, licensing risk |
| B3. Backup complexity | Only Cloudron-managed DB + /app/data | SQLite or custom backup needs | Internal data stores needing snapshot APIs |
| B4. Platform fit | Standard HTTP behind reverse proxy | WebSocket (needs nginx config) | Needs raw TCP/UDP ports or assumes horizontal scaling |
| B5. Config drift | Config from env vars, no self-modification | Plugin/extension system at runtime | Self-updating, modifies own code |

**Compliance subtotal** (max 13): 0-2 Low, 3-5 Moderate, 6-8 High, 9+ Very High.

**Decision rule**: If structural score is 10+ or compliance score is 9+, recommend against packaging.

### Step 2: Gather Evidence

Fetch from the upstream repo before scoring:

1. `docker-compose.yml` / `compose.yml` — **the single most valuable artifact** (reveals true dependency graph)
2. `Dockerfile` (build process and runtime)
3. Dependency files (`package.json`, `requirements.txt`, `go.mod`, `Cargo.toml`, `composer.json`)
4. Auth documentation (search for "LDAP", "OIDC", "SSO", "SAML")
5. GitHub releases page (release frequency, stability)
6. Upstream self-hosting/deployment docs

### Step 3: Pre-Packaging Research

1. **Forum search**: `https://forum.cloudron.io/search?term=APP_NAME&in=titles`
2. **App store**: `cloudron appstore search APP_NAME`
3. **Reference apps**: See [cloudron-git-reference.md](cloudron-git-reference.md) for finding apps by technology, GitLab API usage, and recommended reference apps by use case.

## Base Image Selection

**Always start from `cloudron/base:5.0.0`.** Do not start from the upstream app's Docker image.

The upstream image trap: many complex apps ship monolithic Docker images that bundle their own databases, reverse proxies, and init systems. Starting from these means fighting their assumptions — this has caused multi-week packaging failures (e.g., docassemble: 25 symlinks, 15-20 minute boot times).

The correct approach: read the upstream `docker-compose.yml` to understand dependencies, then install the app on `cloudron/base` using its package manager (pip, npm, composer, go build, or download binary).

**Multi-stage builds**: Only when the app's build toolchain is exotic or compilation on `cloudron/base` is impractical. Build in the upstream image, then `COPY --from` artifacts into a final `cloudron/base` stage.

**Alpine/musl warning**: Binaries compiled in Alpine (musl libc) will NOT run on `cloudron/base` (Ubuntu/glibc). Always compile in a glibc-based builder stage or use pre-built glibc binaries.

**Base image contents (verified on Cloudron 9.1.3)**:

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 24.04.1 LTS | |
| Node.js | 24.x (default PATH) | Node 22 LTS at `/usr/local/node-22.14.0` (set PATH explicitly) |
| Python | 3.12.3 | pip 24.0 |
| PHP | 8.3.6 | Extensions: redis, imagick, ldap, gd, mbstring, etc. |
| Nginx | 1.24.0 | |
| Apache | 2.4.58 | |
| Supervisor | 4.2.5 | For multi-process management |
| gosu | 1.17 | |
| gcc/g++ | 13.3.0 | Build tools available |
| ImageMagick | 6.9.12 | |
| ffmpeg | 6.1.1 | |
| psql client | 16.6 | |
| mysql client | 8.0.41 | |
| redis-cli | 7.4.2 | |
| mongosh | 2.4.0 | |

**NOT in the base image** (install in Dockerfile if needed): Ruby, Go, Java, Rust, pandoc, wkhtmltopdf.

## CloudronManifest.json

For the full field reference, see [manifest-ref.md](cloudron-app-packaging-skill/manifest-ref.md). For addon options and environment variables, see [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md).

**Key patterns**:

- Read env vars at runtime on every start — values can change across restarts
- Run DB migrations on each start
- `localstorage` is MANDATORY for all apps that need persistent data
- Health check path must return HTTP 200 unauthenticated (common: `/health`, `/api/health`, `/ping`, `/`)

### Memory Limit Guidelines

| App Type | Recommended | Notes |
|----------|-------------|-------|
| Static/Simple PHP | 128-256 MB | |
| Node.js/Go/Rust | 256-512 MB | |
| PHP with workers | 512-768 MB | |
| Python/Ruby | 512-768 MB | |
| Java/JVM | 1024+ MB | JVM heap overhead |

`memoryLimit` is in bytes: 256MB = 268435456, 512MB = 536870912, 1GB = 1073741824.

**Reading memory limit at runtime** (for memory-aware worker counts):

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

### TCP/UDP Port Exposure

```json
{
  "tcpPorts": {
    "XMPP_C2S_PORT": {
      "title": "XMPP Client",
      "description": "XMPP client-to-server port",
      "containerPort": 5222,
      "defaultValue": 5222
    }
  }
}
```

Port values are exposed as environment variables (e.g., `XMPP_C2S_PORT`). Apps using TCP/UDP ports must handle their own TLS termination.

### 9.1+ Manifest Features

- **`persistentDirs`**: Directories that persist across updates without the `localstorage` addon.
- **`backupCommand` / `restoreCommand`**: Custom commands for apps with special backup needs.
- **SQLite backup declaration**: `"localstorage": { "sqlite": { "paths": ["/app/data/db/app.db"] } }`

### General Variables (Always Available)

```bash
CLOUDRON_APP_ORIGIN=https://app.domain.com  # Full URL with protocol
CLOUDRON_APP_DOMAIN=app.domain.com          # Domain only
CLOUDRON=1                                   # Always set to "1"
```

## Filesystem Permissions

| Path | Runtime State | Purpose |
|------|---------------|---------|
| `/app/code` | READ-ONLY | Application code |
| `/app/data` | READ-WRITE | Persistent storage (backed up) |
| `/run` | READ-WRITE (wiped on restart) | Sockets, PIDs, sessions |
| `/tmp` | READ-WRITE (wiped on restart) | Temporary files, caches |

### The Symlink Dance

When apps expect to write to paths under `/app/code`:

**Build Time (Dockerfile)**:

```dockerfile
# Preserve defaults for first-run initialization
RUN mkdir -p /app/code/defaults && \
    mv /app/code/config /app/code/defaults/config 2>/dev/null || true && \
    mv /app/code/storage /app/code/defaults/storage 2>/dev/null || true
```

**Runtime (start.sh)**:

```bash
mkdir -p /app/data/config /app/data/storage /app/data/logs

if [[ ! -f /app/data/.initialized ]]; then
    cp -rn /app/code/defaults/config/* /app/data/config/ 2>/dev/null || true
    cp -rn /app/code/defaults/storage/* /app/data/storage/ 2>/dev/null || true
fi

# Always recreate - safe and idempotent
ln -sfn /app/data/config /app/code/config
ln -sfn /app/data/storage /app/code/storage
ln -sfn /app/data/logs /app/code/logs

chown -R cloudron:cloudron /app/data
touch /app/data/.initialized
```

### Ephemeral vs Persistent Decision

| Data Type | Location | Rationale |
|-----------|----------|-----------|
| User uploads, config files, SQLite DBs | `/app/data/...` | Must survive restarts |
| Sessions, view cache, compiled assets | `/run/...` | Regenerated on start |

## Process Model Selection

```text
Single process app (Node.js, Go, Rust)?
  YES -> Direct exec in start.sh
  NO  -> Multiple processes needed?
           YES -> Use supervisord
           NO  -> Web server manages children (Apache, nginx)?
                    YES -> Direct exec (they handle children)
                    NO  -> Use supervisord
```

## Dockerfile Patterns

### Basic Structure

```dockerfile
FROM cloudron/base:5.0.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    php8.2-fpm \
    php8.2-mysql \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/code
COPY --chown=cloudron:cloudron . /app/code/

RUN mkdir -p /app/code/defaults && \
    mv /app/code/config /app/code/defaults/config 2>/dev/null || true

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

EXPOSE 8000
CMD ["/app/code/start.sh"]
```

### Framework-Specific Patterns

#### PHP Applications

```dockerfile
# PHP temp paths must be writable
RUN rm -rf /var/lib/php/sessions && \
    ln -s /run/php/sessions /var/lib/php/sessions
```

PHP-FPM pool config:

```ini
php_value[session.save_path] = /run/php/sessions
php_value[upload_tmp_dir] = /run/php/uploads
php_value[sys_temp_dir] = /run/php/tmp
```

In start.sh: `mkdir -p /run/php/sessions /run/php/uploads /run/php/tmp`

#### Node.js Applications

```dockerfile
RUN npm ci --production && npm cache clean --force
ENV NODE_ENV=production
```

`node_modules` stays in `/app/code` (never move to `/app/data`).

#### Python Applications

```dockerfile
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
RUN pip install --no-cache-dir -r requirements.txt
```

#### nginx as Reverse Proxy

```nginx
# MANDATORY: Writable temp paths
client_body_temp_path /run/nginx/client_body;
proxy_temp_path /run/nginx/proxy;
fastcgi_temp_path /run/nginx/fastcgi;

server {
    listen 8000;  # Internal port, never 80/443
    root /app/code/public;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
}
```

In start.sh: `mkdir -p /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi`

#### Apache Configuration

```dockerfile
RUN rm /etc/apache2/sites-enabled/* \
    && sed -e 's,^ErrorLog.*,ErrorLog "/dev/stderr",' -i /etc/apache2/apache2.conf \
    && sed -e "s,MaxSpareServers[^:].*,MaxSpareServers 5," -i /etc/apache2/mods-available/mpm_prefork.conf \
    && a2disconf other-vhosts-access-log \
    && echo "Listen 8000" > /etc/apache2/ports.conf
```

## start.sh Architecture

### Complete Template

```bash
#!/bin/bash
set -eu

echo "==> Starting Cloudron App"

# PHASE 1: First-Run Detection
if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
else
    FIRST_RUN=false
fi

# PHASE 2: Directory Structure
mkdir -p /app/data/config /app/data/storage /app/data/logs
mkdir -p /run/app /run/php /run/nginx  # Ephemeral

# PHASE 3: Symlinks (always recreate - idempotent)
ln -sfn /app/data/config /app/code/config
ln -sfn /app/data/storage /app/code/storage
ln -sfn /app/data/logs /app/code/logs

# PHASE 4: First-Run Initialization
if [[ "$FIRST_RUN" == "true" ]]; then
    cp -rn /app/code/defaults/config/* /app/data/config/ 2>/dev/null || true
fi

# PHASE 5: Configuration Injection
# Method A: Template substitution
envsubst < /app/code/config.template > /app/data/config/app.conf

# Method B: Direct generation
cat > /app/data/config/database.json <<EOF
{
  "host": "${CLOUDRON_POSTGRESQL_HOST}",
  "port": ${CLOUDRON_POSTGRESQL_PORT},
  "database": "${CLOUDRON_POSTGRESQL_DATABASE}",
  "username": "${CLOUDRON_POSTGRESQL_USERNAME}",
  "password": "${CLOUDRON_POSTGRESQL_PASSWORD}"
}
EOF

# Method C: sed for simple replacements
sed -i "s|APP_URL=.*|APP_URL=${CLOUDRON_APP_ORIGIN}|" /app/data/config/.env

# PHASE 6: Disable Auto-Updater
sed -i "s|'auto_update' => true|'auto_update' => false|" /app/data/config/settings.php 2>/dev/null || true

# PHASE 7: Database Migrations
gosu cloudron:cloudron /app/code/bin/migrate --force

# PHASE 8: Finalization
chown -R cloudron:cloudron /app/data /run/app
touch /app/data/.initialized

# PHASE 9: Process Launch
exec gosu cloudron:cloudron node /app/code/server.js
```

### Multi-Process with Supervisord

```ini
# /app/code/supervisord.conf
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

[program:worker]
command=/app/code/bin/worker
directory=/app/code
user=cloudron
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

End of start.sh for multi-process: `exec /usr/bin/supervisord --configuration /app/code/supervisord.conf`

## The Message Broker Problem

Cloudron has no AMQP addon. Apps using Celery, Sidekiq, or any AMQP-dependent task queue need a broker solution.

**Option A: Redis as broker (preferred)**. If the app supports Redis as a broker backend (Celery does natively), use the Cloudron Redis addon:

```python
CELERY_BROKER_URL = os.environ['CLOUDRON_REDIS_URL']
CELERY_RESULT_BACKEND = os.environ['CLOUDRON_REDIS_URL']
```

**Option B: LavinMQ (when AMQP is required)**. LavinMQ is a lightweight AMQP broker (~40 MB RAM, single binary, drop-in RabbitMQ replacement):

```dockerfile
RUN curl -fsSL https://packagecloud.io/cloudamqp/lavinmq/gpgkey | gpg --dearmor -o /usr/share/keyrings/lavinmq.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/lavinmq.gpg] https://packagecloud.io/cloudamqp/lavinmq/ubuntu/ noble main" \
    > /etc/apt/sources.list.d/lavinmq.list && \
    apt-get update && apt-get install -y lavinmq && \
    rm -rf /var/cache/apt /var/lib/apt/lists/*
```

Store data under `/app/data/lavinmq` and run as a Supervisor program.

## Common Anti-Patterns

| Anti-pattern | Wrong | Correct |
|---|---|---|
| Starting from upstream image | `FROM someapp/monolith:latest` | `FROM cloudron/base:5.0.0` + install app |
| Writing to /app/code | `echo "data" > /app/code/cache/file.txt` | `echo "data" > /app/data/cache/file.txt` |
| Running as root | `node /app/code/server.js` | `exec gosu cloudron:cloudron node /app/code/server.js` |
| Missing exec | `gosu cloudron:cloudron node server.js` | `exec gosu cloudron:cloudron node server.js` |
| Non-idempotent start.sh | `cp /app/code/defaults/config.json /app/data/` | `cp -n /app/code/defaults/config.json /app/data/ 2>/dev/null \|\| true` |
| Hardcoded URLs | `const baseUrl = "https://myapp.example.com"` | `const baseUrl = process.env.CLOUDRON_APP_ORIGIN` |
| Bundling databases | `RUN apt-get install -y postgresql redis-server` | Use Cloudron addons |
| Caching env vars | `const dbHost = process.env.CLOUDRON_MYSQL_HOST` (stored) | Read `process.env.CLOUDRON_MYSQL_HOST` fresh each time |

## Upgrade & Migration Handling

### Version Tracking Pattern

```bash
CURRENT_VERSION="2.0.0"
VERSION_FILE="/app/data/.app_version"

if [[ -f "$VERSION_FILE" ]]; then
    PREVIOUS_VERSION=$(cat "$VERSION_FILE")
    if [[ "$PREVIOUS_VERSION" != "$CURRENT_VERSION" ]]; then
        echo "==> Upgrading from $PREVIOUS_VERSION to $CURRENT_VERSION"
        if [[ "$PREVIOUS_VERSION" < "1.5.0" ]]; then
            echo "==> Running 1.5.0 migration"
            # migration commands
        fi
    fi
fi

echo "$CURRENT_VERSION" > "$VERSION_FILE"
```

### Migration Safety

- Migrations MUST be idempotent
- Use framework migration tracking (Laravel, Django, Rails, etc.)
- For raw SQL: `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`

## Troubleshooting

| Issue | Solution |
|-------|----------|
| App won't start | `cloudron logs --app testapp` / `cloudron debug --app testapp` |
| Permission denied | `chown -R cloudron:cloudron /app/data` — check if writing to read-only path |
| Database connection fails | Verify addon declared in manifest; `cloudron exec --app testapp` then `env \| grep CLOUDRON` |
| Health check fails | `curl -v http://localhost:8000/health` — verify app listens on httpPort |
| Memory limit exceeded | Increase `memoryLimit` in manifest; check for memory leaks; optimize worker counts |

## Validation Checklist

```text
[ ] Fresh install completes without errors
[ ] App survives restart (cloudron restart --app)
[ ] Health check returns 200
[ ] File uploads persist across restarts
[ ] Database connections work
[ ] Email sending works (if applicable)
[ ] Memory stays within limit
[ ] Upgrade from previous version works
[ ] Backup/restore cycle works
[ ] Auto-updater is disabled
[ ] Logs stream to stdout/stderr
```

## Publishing

Fork the app store repo at https://git.cloudron.io/cloudron/appstore, add your app directory with manifest and icon, and submit a merge request. See: https://docs.cloudron.io/packaging/publishing/
