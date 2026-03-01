---
description: "Official Cloudron app packaging skill - Dockerfile patterns, manifest, addons, build methods"
mode: subagent
imported_from: external
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
  task: true
---

# Cloudron App Packaging (Official Skill)

A Cloudron app is a Docker image with a `CloudronManifest.json`. The platform provides a readonly filesystem, addon services, and a managed backup/restore lifecycle.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Official upstream skill for Cloudron app packaging
- **Upstream**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-app-packaging`)
- **Docs**: [docs.cloudron.io/packaging](https://docs.cloudron.io/packaging/)
- **Reference files**: `cloudron-app-packaging-skill/manifest-ref.md`, `cloudron-app-packaging-skill/addons-ref.md`
- **Also see**: `cloudron-app-packaging.md` (native aidevops guide with helper scripts and local dev workflow)

<!-- AI-CONTEXT-END -->

## Quick Start

```bash
npm install -g cloudron
cloudron login my.example.com
cloudron init                    # creates CloudronManifest.json and Dockerfile
cloudron install                 # uploads source, builds on server, installs app
cloudron update                  # re-uploads, rebuilds, updates running app
```

## Key Constraints

- Filesystem is **readonly** at runtime. Writable dirs: `/tmp`, `/run`, `/app/data`.
- Databases, caching, email, and auth are **addons** -- env vars injected at runtime.
- `CloudronManifest.json` declares metadata, ports, and addon requirements.
- App listens on HTTP (not HTTPS). The platform handles TLS termination.
- Default memory limit is 256 MB (RAM + swap). Set `memoryLimit` in manifest to change.

## Build Methods (9.1+)

### On-Server Build (Default, Recommended)

`cloudron install` and `cloudron update` upload the source and build on the server. No local Docker needed. Source is part of the app backup -- on restore, the app rebuilds from the backed-up source.

```bash
cloudron install --location myapp    # uploads, builds, installs
cloudron update --app myapp          # uploads, rebuilds, updates
```

### Local Docker Build

Build locally, push to registry, install with image:

```bash
docker login
cloudron build              # builds, tags, pushes
cloudron install             # detects the built image
cloudron build && cloudron update   # update cycle
```

### Build Service

Offload builds to a remote Docker Builder App:

```bash
cloudron build login         # authenticate with build service
cloudron build               # source sent to remote builder
```

## Dockerfile Patterns

Name the file `Dockerfile`, `Dockerfile.cloudron`, or `cloudron/Dockerfile`.

### Typical Structure

```dockerfile
FROM cloudron/base:5.0.0@sha256:...

RUN mkdir -p /app/code
WORKDIR /app/code

# Install app
COPY . /app/code/

# Create symlinks for runtime config
RUN ln -sf /run/app/config.json /app/code/config.json

# Ensure start script is executable
RUN chmod +x /app/code/start.sh

CMD [ "/app/code/start.sh" ]
```

### start.sh Conventions

- Runs as root. Use `gosu cloudron:cloudron <cmd>` to drop privileges.
- Fix ownership on every start (backups/restores can reset it):

  ```bash
  chown -R cloudron:cloudron /app/data
  ```

- Use `exec` as the last command to forward SIGTERM:

  ```bash
  exec gosu cloudron:cloudron node /app/code/server.js
  ```

- Track first-run with a marker file:

  ```bash
  if [[ ! -f /app/data/.initialized ]]; then
    # first-time setup
    touch /app/data/.initialized
  fi
  ```

### Writable Directories

| Path | Persists across restarts | Backed up |
|------|--------------------------|-----------|
| `/tmp` | No | No |
| `/run` | No | No |
| `/app/data` | Yes | Yes (requires `localstorage` addon) |

### Logging

Log to stdout/stderr. The platform manages rotation and streaming. If the app cannot log to stdout, write to `/run/<subdir>/*.log` (two levels deep). These files are autorotated.

### Multiple Processes

Use `supervisor` or `pm2` when the app has multiple components. Configure supervisor to send output to stdout:

```ini
[program:app]
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

### Memory-Aware Worker Count

```bash
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    memory_limit=$(cat /sys/fs/cgroup/memory.max)
    [[ "${memory_limit}" == "max" ]] && memory_limit=$((2 * 1024 * 1024 * 1024))
else
    memory_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
worker_count=$((memory_limit / 1024 / 1024 / 150))
worker_count=$((worker_count > 8 ? 8 : worker_count))
worker_count=$((worker_count < 1 ? 1 : worker_count))
```

## Manifest Essentials

Minimal `CloudronManifest.json`:

```json
{
  "id": "com.example.myapp",
  "title": "My App",
  "author": "Jane Developer <jane@example.com>",
  "version": "1.0.0",
  "healthCheckPath": "/",
  "httpPort": 8000,
  "addons": {
    "localstorage": {}
  },
  "manifestVersion": 2
}
```

For the full field reference, see [manifest-ref.md](cloudron-app-packaging-skill/manifest-ref.md).

## Addons Overview

| Addon | Provides | Key env var |
|-------|----------|-------------|
| `localstorage` | Writable `/app/data`, backup support | -- |
| `mysql` | MySQL 8.0 database | `CLOUDRON_MYSQL_URL` |
| `postgresql` | PostgreSQL 14.9 database | `CLOUDRON_POSTGRESQL_URL` |
| `mongodb` | MongoDB 8.0 database | `CLOUDRON_MONGODB_URL` |
| `redis` | Redis 8.4 cache (persistent) | `CLOUDRON_REDIS_URL` |
| `ldap` | LDAP v3 authentication | `CLOUDRON_LDAP_URL` |
| `oidc` | OpenID Connect authentication | `CLOUDRON_OIDC_DISCOVERY_URL` |
| `sendmail` | Outgoing email (SMTP relay) | `CLOUDRON_MAIL_SMTP_SERVER` |
| `recvmail` | Incoming email (IMAP) | `CLOUDRON_MAIL_IMAP_SERVER` |
| `proxyauth` | Authentication wall | -- |
| `scheduler` | Cron-like periodic tasks | -- |
| `tls` | App certificate files | `/etc/certs/tls_cert.pem` |
| `docker` | Create containers (restricted) | `CLOUDRON_DOCKER_HOST` |

Read env vars at runtime on every start -- values can change across restarts. Run DB migrations on each start.

For full env var lists and addon options, see [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md).

## Stack-Specific Notes

**Apache** -- Disable default sites, set `Listen 8000`, log errors to stderr, start with `exec /usr/sbin/apache2 -DFOREGROUND`.

**Nginx** -- Use `/run/` for temp paths (`client_body_temp_path`, `proxy_temp_path`, etc.). Run with supervisor alongside the app.

**PHP** -- Move sessions from `/var/lib/php/sessions` to `/run/php/sessions` via symlink.

**Java** -- Read cgroup memory limit and set `-XX:MaxRAM` accordingly.

## Debugging

```bash
cloudron logs                # view app logs
cloudron logs -f             # follow logs in real time
cloudron exec                # shell into running app
cloudron debug               # pause app (read-write filesystem)
cloudron debug --disable     # exit debug mode
```

## Examples

All published Cloudron apps are open source: https://git.cloudron.io/packages

Browse by framework:
[PHP](https://git.cloudron.io/explore/projects?tag=php) |
[Node](https://git.cloudron.io/explore/projects?tag=node) |
[Python](https://git.cloudron.io/explore/projects?tag=python) |
[Ruby/Rails](https://git.cloudron.io/explore/projects?tag=rails) |
[Java](https://git.cloudron.io/explore/projects?tag=java) |
[Go](https://git.cloudron.io/explore/projects?tag=go) |
[Rust](https://git.cloudron.io/explore/projects?tag=rust)
