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

- **Purpose**: Package any web application for Cloudron deployment
- **Docs**: [docs.cloudron.io/packaging](https://docs.cloudron.io/packaging/tutorial/)
- **Source Code**: [git.cloudron.io/packages](https://git.cloudron.io/packages) (200+ official app packages)
- **By Technology**: [git.cloudron.io/explore/projects/topics](https://git.cloudron.io/explore/projects/topics) (PHP, Node, Python, Go, etc.)
- **CLI**: `npm install -g cloudron` then `cloudron login my.cloudron.example`
- **Workflow**: `cloudron build && cloudron update --app testapp`
- **Debug**: `cloudron exec --app testapp` or `cloudron debug --app testapp`
- **Forum**: [forum.cloudron.io/category/96/app-packaging-development](https://forum.cloudron.io/category/96/app-packaging-development)

**Golden Rules** (violations cause package failure):
1. `/app/code` is READ-ONLY at runtime - use `/app/data` for persistent storage
2. Run processes as `cloudron` user (UID 1000) via `exec gosu cloudron:cloudron`
3. Use Cloudron addons (mysql, postgresql, redis) - never bundle databases
4. Disable built-in auto-updaters - Cloudron manages updates via image replacement
5. App receives HTTP (not HTTPS) - Cloudron's nginx terminates SSL

**File Structure**:

```text
my-app/
  CloudronManifest.json    # App metadata and addon requirements
  Dockerfile               # Build instructions (or Dockerfile.cloudron)
  start.sh                 # Runtime entry point
  logo.png                 # 256x256 app icon
```

**Quick Start**:

```bash
# Initialize new app package
cloudron init

# Build and test
cloudron build
cloudron install --location testapp

# Iterate
cloudron build && cloudron update --app testapp
cloudron logs -f --app testapp
```
<!-- AI-CONTEXT-END -->

## Pre-Packaging Assessment

Before writing any code, assess whether the app is a good candidate for Cloudron packaging. Initial packaging is roughly 25% of total effort. The remaining 75% is SSO integration, upgrade path testing, backup correctness, and ongoing maintenance. A structured assessment upfront prevents wasted weeks on impractical candidates.

### Step 1: Feasibility Assessment (Two-Axis Scoring)

Score the app across two dimensions. If either score exceeds the "Hard" threshold, reconsider whether to proceed.

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

**Decision rule**: If structural score is 10+ or compliance score is 9+, recommend against packaging and suggest alternatives. Document the assessment in the PR or issue for future reference.

### Step 2: Gather Evidence

Before scoring, fetch and read these files from the upstream repo:

1. `docker-compose.yml` / `compose.yml` (reveals true dependency graph)
2. `Dockerfile` (reveals build process and runtime)
3. `package.json` / `requirements.txt` / `go.mod` / `Cargo.toml` / `composer.json`
4. Auth documentation (search for "LDAP", "OIDC", "SSO", "SAML")
5. GitHub releases page (release frequency, stability)
6. Upstream self-hosting/deployment docs

**The compose file is the single most valuable artifact.** It reveals the true dependency graph: which databases, caches, brokers, and workers the app actually needs. Ignore the monolithic Docker image if one exists.

### Step 3: Pre-Packaging Research

Search the Cloudron forum for existing knowledge:

1. **Search by app name**: `https://forum.cloudron.io/search?term=APP_NAME&in=titles`
   Forum threads with the app name in the title often contain:
   - Community packaging attempts (partial or complete) you can build on
   - Known gotchas, workarounds, and platform-specific quirks
   - Addon requirements and configuration insights from real deployments
   - User experience reports on complexity, stability, and resource usage
   - Upstream compatibility issues with Cloudron's read-only filesystem or auth model

2. **Check the packaging category**: [forum.cloudron.io/category/96](https://forum.cloudron.io/category/96/app-packaging-development) for active packaging discussions

3. **Search the app store**: `cloudron appstore search APP_NAME` to check if an official or community package already exists

This research often saves significant trial-and-error, especially for apps with non-standard storage, auth, or process models.

## Using git.cloudron.io as Reference

Study real-world packaging patterns from 200+ official Cloudron app packages at https://git.cloudron.io/.

**Full guide**: `cloudron-git-reference.md` - Repository structure, finding apps by technology, GitLab API usage, recommended reference apps by use case, cloning patterns, and common search patterns.

## Overview

Cloudron app packaging creates Docker containers that integrate with Cloudron's platform features: automatic SSL, user management (LDAP/OIDC), backups, and addon services.

**Key Concepts**:
- Apps run in isolated Docker containers with read-only filesystems
- Persistent data stored in `/app/data` (backed up automatically)
- Services (databases, email, auth) provided via addons with environment variables
- Health checks determine app readiness
- Start scripts handle initialization and configuration injection

## Decision Trees

### Base Image Selection

**Always start from `cloudron/base:5.0.0`.** Do not start from the upstream app's Docker image.

The upstream image trap: many complex apps ship monolithic Docker images that bundle their own databases, reverse proxies, and init systems. Starting from these images means fighting their assumptions. You end up disabling services, overriding configs, and debugging interactions between the app's internal process manager and Cloudron's external one. This approach has caused multi-week packaging failures (e.g., docassemble: 25 symlinks, 15-20 minute boot times, fragile result).

The correct approach: read the upstream `docker-compose.yml` to understand the app's true dependencies, then install the app on `cloudron/base` using its package manager (pip, npm, composer, go build, or download binary).

**When multi-stage builds are justified**: Only when the app's build toolchain is exotic or compilation from source on `cloudron/base` is impractical. Build in the upstream image, then `COPY --from` the compiled artifacts into a final stage based on `cloudron/base`.

**Alpine/musl compatibility warning**: If the upstream image is Alpine-based (uses musl libc), binaries compiled inside it will NOT run on `cloudron/base` (Ubuntu/glibc). You will get `libc.musl-x86_64.so.1: cannot open shared object file` errors. Always compile in a glibc-based builder stage or use pre-built glibc binaries.

**Why cloudron/base is the safe default**:
- Pre-configured locales (prevents unicode crashes)
- Includes `gosu` for privilege dropping
- Web terminal compatibility (bash, utilities)
- Consistent glibc environment (Ubuntu 24.04 LTS)
- Security updates managed by Cloudron team
- Shared layers across all Cloudron apps (disk efficient)

**Base image contents (verified on Cloudron 9.1.3)**:

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 24.04.1 LTS | |
| Node.js | 24.x (default PATH) | Node 22 LTS at `/usr/local/node-22.14.0` (set PATH explicitly to use) |
| Python | 3.12.3 | pip 24.0 |
| PHP | 8.3.6 | Extensive extensions: redis, imagick, ldap, gd, mbstring, etc. |
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

**Version check**: https://hub.docker.com/r/cloudron/base/tags

### Addon Selection

| App Needs | Addon | Environment Variables |
|-----------|-------|----------------------|
| Persistent storage | `localstorage` | (provides `/app/data`) |
| MySQL/MariaDB | `mysql` | `CLOUDRON_MYSQL_*` |
| PostgreSQL | `postgresql` | `CLOUDRON_POSTGRESQL_*` |
| MongoDB | `mongodb` | `CLOUDRON_MONGODB_*` |
| Redis cache | `redis` | `CLOUDRON_REDIS_*` |
| Send email | `sendmail` | `CLOUDRON_MAIL_SMTP_*` |
| Receive email | `recvmail` | `CLOUDRON_MAIL_IMAP_*` |
| LDAP auth | `ldap` | `CLOUDRON_LDAP_*` |
| OIDC auth | `oidc` | `CLOUDRON_OIDC_*` |
| Cron jobs | `scheduler` | (config in manifest) |
| TLS certs | `tls` | `/etc/certs/tls_*.pem` |

**Note**: `localstorage` is MANDATORY for all apps that need persistent data. For full env var lists and addon options, see [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md).

### Process Model Selection

```text
Single process app (Node.js, Go, Rust)?
  YES -> Direct exec in start.sh
  NO  -> Multiple processes needed?
           YES -> Use supervisord
           NO  -> Web server manages children (Apache, nginx)?
                    YES -> Direct exec (they handle children)
                    NO  -> Use supervisord
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
# Create persistent directories
mkdir -p /app/data/config /app/data/storage /app/data/logs

# First-run: copy defaults
if [[ ! -f /app/data/.initialized ]]; then
    cp -rn /app/code/defaults/config/* /app/data/config/ 2>/dev/null || true
    cp -rn /app/code/defaults/storage/* /app/data/storage/ 2>/dev/null || true
fi

# Create symlinks (always recreate - safe and idempotent)
ln -sfn /app/data/config /app/code/config
ln -sfn /app/data/storage /app/code/storage
ln -sfn /app/data/logs /app/code/logs

# Fix permissions
chown -R cloudron:cloudron /app/data

# Mark initialized
touch /app/data/.initialized
```

### Ephemeral vs Persistent Decision

| Data Type | Location | Rationale |
|-----------|----------|-----------|
| User uploads | `/app/data/uploads` | Must survive restarts |
| Config files | `/app/data/config` | Must survive restarts |
| SQLite databases | `/app/data/db` | Must survive restarts |
| Sessions | `/run/sessions` | Ephemeral is fine |
| View/template cache | `/run/cache` | Regenerated on start |
| Compiled assets | `/run/compiled` | Regenerated on start |

## CloudronManifest.json

### Complete Template

```json
{
  "id": "io.example.myapp",
  "title": "My Application",
  "author": "Your Name <email@example.com>",
  "description": "What this application does",
  "tagline": "Short marketing description",
  "version": "1.0.0",
  "upstreamVersion": "2.5.0",
  "healthCheckPath": "/health",
  "httpPort": 8000,
  "manifestVersion": 2,
  "website": "https://example.com",
  "contactEmail": "support@example.com",
  "icon": "file://logo.png",
  "documentationUrl": "https://docs.example.com",
  "minBoxVersion": "7.4.0",
  "memoryLimit": 536870912,
  "addons": {
    "localstorage": {},
    "postgresql": {}
  },
  "tcpPorts": {}
}
```

### Memory Limit Guidelines

| App Type | Recommended | Notes |
|----------|-------------|-------|
| Static/Simple PHP | 128-256 MB | |
| Node.js/Go/Rust | 256-512 MB | |
| PHP with workers | 512-768 MB | |
| Python/Ruby | 512-768 MB | |
| Java/JVM | 1024+ MB | JVM heap overhead |
| Electron-based | 1024+ MB | |

**Note**: `memoryLimit` is in bytes. 256MB = 268435456, 512MB = 536870912, 1GB = 1073741824

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

Cloudron supports exposing raw TCP and UDP ports via the manifest, not just HTTP. This is required for protocols like XMPP (5222/5269), MQTT, game servers, or any non-HTTP service.

```json
{
  "tcpPorts": {
    "XMPP_C2S_PORT": {
      "title": "XMPP Client",
      "description": "XMPP client-to-server port",
      "containerPort": 5222,
      "defaultValue": 5222
    }
  },
  "udpPorts": {
    "STUN_PORT": {
      "title": "STUN/TURN",
      "description": "STUN/TURN for voice/video",
      "containerPort": 3478,
      "defaultValue": 3478
    }
  }
}
```

The port values are exposed as environment variables (e.g., `XMPP_C2S_PORT`) so the app can read the externally mapped port. Note that apps using TCP/UDP ports must handle their own TLS termination for those ports (Cloudron's reverse proxy only handles HTTP).

### 9.1+ Manifest Features

**`persistentDirs`**: Directories that persist across updates without needing the `localstorage` addon. Useful for apps that write to specific paths outside `/app/data`.

**`backupCommand` / `restoreCommand`**: Custom commands run during backup/restore for apps with special backup needs (e.g., consistent SQLite snapshots, application-level dump/restore).

```json
{
  "addons": {
    "localstorage": {
      "sqlite": {
        "paths": ["/app/data/db/app.db"]
      }
    }
  },
  "backupCommand": "/app/code/backup.sh",
  "restoreCommand": "/app/code/restore.sh"
}
```

### Health Check Requirements

- Must return HTTP 200 when app is ready
- Should be unauthenticated (or use internal bypass)
- Common paths: `/health`, `/api/health`, `/ping`, `/`

## Dockerfile Patterns

### Basic Structure

```dockerfile
FROM cloudron/base:5.0.0

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    php8.2-fpm \
    php8.2-mysql \
    && rm -rf /var/lib/apt/lists/*

# Copy application code
WORKDIR /app/code
COPY --chown=cloudron:cloudron . /app/code/

# Preserve defaults for first-run
RUN mkdir -p /app/code/defaults && \
    mv /app/code/config /app/code/defaults/config 2>/dev/null || true

# Add start script
COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

# Expose port (documentation only, Cloudron uses httpPort from manifest)
EXPOSE 8000

CMD ["/app/code/start.sh"]
```

### Framework-Specific Patterns

#### PHP Applications

```dockerfile
# PHP temp paths must be writable
RUN rm -rf /var/lib/php/sessions && \
    ln -s /run/php/sessions /var/lib/php/sessions

# In start.sh:
mkdir -p /run/php/sessions /run/php/uploads /run/php/tmp
chown -R www-data:www-data /run/php
```

PHP-FPM pool config:

```ini
php_value[session.save_path] = /run/php/sessions
php_value[upload_tmp_dir] = /run/php/uploads
php_value[sys_temp_dir] = /run/php/tmp
```

#### Node.js Applications

```dockerfile
# Build time
RUN npm ci --production && npm cache clean --force

# Runtime
ENV NODE_ENV=production
```

**Note**: `node_modules` stays in `/app/code` (never move to `/app/data`)

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

In start.sh:

```bash
mkdir -p /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi
```

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

# ============================================
# PHASE 1: First-Run Detection
# ============================================
if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
    echo "==> First run detected"
else
    FIRST_RUN=false
fi

# ============================================
# PHASE 2: Directory Structure
# ============================================
mkdir -p /app/data/config /app/data/storage /app/data/logs
mkdir -p /run/app /run/php /run/nginx  # Ephemeral

# ============================================
# PHASE 3: Symlinks (always recreate - idempotent)
# ============================================
ln -sfn /app/data/config /app/code/config
ln -sfn /app/data/storage /app/code/storage
ln -sfn /app/data/logs /app/code/logs

# ============================================
# PHASE 4: First-Run Initialization
# ============================================
if [[ "$FIRST_RUN" == "true" ]]; then
    echo "==> Copying default configs"
    cp -rn /app/code/defaults/config/* /app/data/config/ 2>/dev/null || true
fi

# ============================================
# PHASE 5: Configuration Injection
# ============================================
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

# ============================================
# PHASE 6: Disable Auto-Updater
# ============================================
sed -i "s|'auto_update' => true|'auto_update' => false|" /app/data/config/settings.php 2>/dev/null || true

# ============================================
# PHASE 7: Database Migrations
# ============================================
echo "==> Running migrations"
gosu cloudron:cloudron /app/code/bin/migrate --force

# ============================================
# PHASE 8: Finalization
# ============================================
chown -R cloudron:cloudron /app/data /run/app

# Mark initialized
touch /app/data/.initialized

# ============================================
# PHASE 9: Process Launch
# ============================================
echo "==> Launching application"
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

End of start.sh for multi-process:

```bash
exec /usr/bin/supervisord --configuration /app/code/supervisord.conf
```

## Addon Environment Variables

For the full environment variable reference for all addons (`mysql`, `postgresql`, `mongodb`, `redis`, `ldap`, `oidc`, `sendmail`, `recvmail`, `email`, `proxyauth`, `scheduler`, `tls`, `turn`, `docker`) including addon-specific options, see [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md).

**Key patterns**:

- Read env vars at runtime on every start — values can change across restarts.
- Run DB migrations on each start.

### General Variables (Always Available)

These are always set, regardless of which addons are declared:

```bash
CLOUDRON_APP_ORIGIN=https://app.domain.com  # Full URL with protocol
CLOUDRON_APP_DOMAIN=app.domain.com          # Domain only
CLOUDRON=1                                   # Always set to "1"
```

## Development Workflow

### Initial Setup

```bash
# Install Cloudron CLI
npm install -g cloudron

# Login to your Cloudron instance
cloudron login my.cloudron.example

# Initialize new app (creates manifest and basic structure)
cloudron init
```

### Build-Test-Iterate Cycle

```bash
# Build Docker image (auto-tags with timestamp)
cloudron build

# First install
cloudron install --location testapp

# View logs
cloudron logs -f --app testapp

# After changes, rebuild and update
cloudron build && cloudron update --app testapp

# Debug mode (pauses app, makes filesystem writable)
cloudron debug --app testapp

# Shell into running container
cloudron exec --app testapp

# Disable debug mode
cloudron debug --disable --app testapp

# Cleanup
cloudron uninstall --app testapp
```

### Validation Checklist

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

## The Message Broker Problem

Cloudron has no AMQP addon. Apps using Celery, Sidekiq, or any AMQP-dependent task queue need a broker solution.

**Option A: Redis as broker (preferred)**. If the app supports Redis as a broker backend (Celery does natively), use the Cloudron Redis addon:

```python
# Celery with Redis broker
CELERY_BROKER_URL = os.environ['CLOUDRON_REDIS_URL']
CELERY_RESULT_BACKEND = os.environ['CLOUDRON_REDIS_URL']
```

**Option B: LavinMQ (when AMQP is required)**. LavinMQ is a lightweight AMQP broker (~40 MB RAM, single binary, drop-in RabbitMQ replacement). Install in the Dockerfile and run under Supervisor:

```dockerfile
RUN curl -fsSL https://packagecloud.io/cloudamqp/lavinmq/gpgkey | gpg --dearmor -o /usr/share/keyrings/lavinmq.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/lavinmq.gpg] https://packagecloud.io/cloudamqp/lavinmq/ubuntu/ noble main" \
    > /etc/apt/sources.list.d/lavinmq.list && \
    apt-get update && apt-get install -y lavinmq && \
    rm -rf /var/cache/apt /var/lib/apt/lists/*
```

Store data under `/app/data/lavinmq` and run as a Supervisor program.

## Anti-Patterns to Avoid

### Starting from the upstream Docker image

```dockerfile
# WRONG - Fighting the image's assumptions about bundled services
FROM someapp/monolith:latest
# ... weeks of disabling internal postgres, redis, nginx ...

# CORRECT - Install the app on cloudron/base
FROM cloudron/base:5.0.0
RUN pip install someapp  # or npm install, go build, download binary
```

### Writing to /app/code

```bash
# WRONG - Read-only filesystem
echo "data" > /app/code/cache/file.txt

# CORRECT
echo "data" > /app/data/cache/file.txt
```

### Running as root

```bash
# WRONG
node /app/code/server.js

# CORRECT
exec gosu cloudron:cloudron node /app/code/server.js
```

### Missing exec

```bash
# WRONG - Signals won't propagate, container won't stop gracefully
gosu cloudron:cloudron node server.js

# CORRECT
exec gosu cloudron:cloudron node server.js
```

### Non-idempotent start.sh

```bash
# WRONG - Fails on second run if file exists
cp /app/code/defaults/config.json /app/data/

# CORRECT - Safe to repeat
cp -n /app/code/defaults/config.json /app/data/ 2>/dev/null || true
```

### Hardcoded URLs

```javascript
// WRONG
const baseUrl = "https://myapp.example.com";

// CORRECT
const baseUrl = process.env.CLOUDRON_APP_ORIGIN;
```

### Bundling databases

```dockerfile
# WRONG - Use Cloudron addons instead
RUN apt-get install -y postgresql redis-server
```

### Caching environment variables

```javascript
// WRONG - Variables can change on restart
const dbHost = process.env.CLOUDRON_MYSQL_HOST;
// ... later in code
connect(dbHost);

// CORRECT - Read fresh each time
connect(process.env.CLOUDRON_MYSQL_HOST);
```

## Upgrade & Migration Handling

### Version Tracking Pattern

```bash
CURRENT_VERSION="2.0.0"
VERSION_FILE="/app/data/.app_version"

if [[ -f "$VERSION_FILE" ]]; then
    PREVIOUS_VERSION=$(cat "$VERSION_FILE")
    if [[ "$PREVIOUS_VERSION" != "$CURRENT_VERSION" ]]; then
        echo "==> Upgrading from $PREVIOUS_VERSION to $CURRENT_VERSION"
        # Run version-specific migrations
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

## Local Development with aidevops

When developing Cloudron app packages locally:

```bash
# Create repo in ~/Git/
mkdir ~/Git/cloudron-myapp
cd ~/Git/cloudron-myapp

# Initialize with aidevops
aidevops init

# Initialize Cloudron package
cloudron init

# Structure
# ~/Git/cloudron-myapp/
#   .agents/                    # aidevops config
#   CloudronManifest.json      # Cloudron manifest
#   Dockerfile                 # Build instructions
#   start.sh                   # Entry point
#   logo.png                   # App icon
```

### Recommended .gitignore

```gitignore
# Cloudron
.cloudron/

# aidevops
.agents/loop-state/
*.local.md

# Build artifacts
node_modules/
vendor/
dist/
```

## Publishing to Cloudron App Store

Once your app is tested and stable:

1. **Fork the app store repo**: https://git.cloudron.io/cloudron/appstore
2. **Add your app**: Create directory with manifest and icon
3. **Submit merge request**: Cloudron team reviews
4. **Approval**: App appears in Cloudron App Store

See: https://docs.cloudron.io/packaging/publishing/

## Troubleshooting

### Common Issues

**App won't start**:

```bash
cloudron logs --app testapp
cloudron debug --app testapp
# Check start.sh for errors
```

**Permission denied errors**:

```bash
# Ensure proper ownership
chown -R cloudron:cloudron /app/data
# Check if writing to read-only path
```

**Database connection fails**:

```bash
# Verify addon is declared in manifest
# Check environment variables are being read correctly
cloudron exec --app testapp
env | grep CLOUDRON
```

**Health check fails**:

```bash
# Verify healthCheckPath returns 200
curl -v http://localhost:8000/health
# Check if app is actually listening on httpPort
```

**Memory limit exceeded**:

```bash
# Increase memoryLimit in manifest
# Check for memory leaks
# Optimize worker counts
```

## Resources

### Official Documentation

- **Packaging Tutorial**: https://docs.cloudron.io/packaging/tutorial/
- **Packaging Reference**: https://docs.cloudron.io/packaging/
- **CLI Reference**: https://docs.cloudron.io/packaging/cli/
- **Publishing Guide**: https://docs.cloudron.io/packaging/publishing/
- **Addon Reference**: https://docs.cloudron.io/packaging/addons/

### git.cloudron.io (Source Code)

The GitLab instance at https://git.cloudron.io/ is the authoritative source for all Cloudron app packages. See "Using git.cloudron.io as Reference" section above for detailed usage.

| Resource | URL |
|----------|-----|
| **All Packages** | https://git.cloudron.io/packages |
| **Explore by Topic** | https://git.cloudron.io/explore/projects/topics |
| **Recently Updated** | https://git.cloudron.io/explore/projects?sort=latest_activity_desc |
| **Platform Code** | https://git.cloudron.io/platform |
| **Documentation Source** | https://git.cloudron.io/docs/docs |
| **GitLab API** | https://git.cloudron.io/api/v4/ |

### Example Repos by Framework

| Framework | Topic URL | Example App |
|-----------|-----------|-------------|
| PHP | https://git.cloudron.io/explore/projects/topics/php | nextcloud-app, wordpress-app |
| Node.js | https://git.cloudron.io/explore/projects/topics/node | ghost-app, nodebb-app |
| Python | https://git.cloudron.io/explore/projects/topics/python | synapse-app |
| Go | https://git.cloudron.io/explore/projects/topics/go | vikunja-app |
| Ruby/Rails | https://git.cloudron.io/explore/projects/topics/rails | discourse-app |
| Java | https://git.cloudron.io/explore/projects/topics/java | metabase-app |

### Other Resources

- **Forum (Packaging)**: https://forum.cloudron.io/category/96/app-packaging-development
- **Base Image Tags**: https://hub.docker.com/r/cloudron/base/tags
- **App Store**: https://cloudron.io/store/index.html
