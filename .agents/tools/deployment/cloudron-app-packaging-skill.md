---
name: cloudron-app-packaging
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

A Cloudron app is a Docker image with a `CloudronManifest.json`. Readonly filesystem, addon services, managed backup/restore lifecycle.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Upstream**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-app-packaging`) | [docs.cloudron.io/packaging](https://docs.cloudron.io/packaging/)
- **Reference files**: `cloudron-app-packaging-skill/manifest-ref.md`, `cloudron-app-packaging-skill/addons-ref.md`
- **Also see**: `cloudron-app-packaging.md` (native aidevops guide — helper scripts, local dev workflow, detailed Dockerfile/start.sh patterns, pre-packaging assessment)

<!-- AI-CONTEXT-END -->

## Key Constraints

| Constraint | Detail |
|------------|--------|
| Filesystem readonly | Writable: `/tmp`, `/run` (ephemeral), `/app/data` (persisted, requires `localstorage` addon) |
| Addons for services | Databases, caching, email, auth via addons — env vars injected at runtime, re-read every start |
| Manifest declares all | `CloudronManifest.json`: metadata, ports, addon requirements |
| HTTP only | App listens HTTP — platform handles TLS |
| Memory default | 256 MB (RAM + swap). Set `memoryLimit` in manifest |

## Build Methods (9.1+)

| Method | Command | Notes |
|--------|---------|-------|
| On-Server (default) | `cloudron install` / `cloudron update` | Uploads source, builds on server. No local Docker. Source backed up; rebuilds on restore |
| Local Docker | `cloudron build` → `cloudron install`/`update` | Requires `docker login` |
| Build Service | `cloudron build login` → `cloudron build` | Source sent to remote builder |

## Dockerfile Patterns

Name: `Dockerfile`, `Dockerfile.cloudron`, or `cloudron/Dockerfile`. See `cloudron-app-packaging.md` "Dockerfile Patterns" for runtime-specific patterns (PHP, Node, Python, nginx, Apache).

```dockerfile
FROM cloudron/base:5.0.0@sha256:...
RUN mkdir -p /app/code
WORKDIR /app/code
COPY . /app/code/
RUN ln -sf /run/app/config.json /app/code/config.json
RUN chmod +x /app/code/start.sh
CMD [ "/app/code/start.sh" ]
```

### start.sh Conventions

- Runs as root — drop privileges: `exec gosu cloudron:cloudron <cmd>`
- Fix ownership every start (backups reset it): `chown -R cloudron:cloudron /app/data`
- Forward SIGTERM with `exec`: `exec gosu cloudron:cloudron node /app/code/server.js`
- First-run marker: `if [[ ! -f /app/data/.initialized ]]; then ...; touch /app/data/.initialized; fi`
- Log to stdout/stderr (platform rotates). Fallback: `/run/<subdir>/*.log` (two levels deep, autorotated)
- Multi-process: use `supervisor` or `pm2`. See `cloudron-app-packaging.md` "start.sh Architecture" for supervisord config and memory-aware worker count

## Manifest Essentials

```json
{
  "id": "com.example.myapp",
  "title": "My App",
  "author": "Jane Developer <jane@example.com>",
  "version": "1.0.0",
  "healthCheckPath": "/",
  "httpPort": 8000,
  "addons": { "localstorage": {} },
  "manifestVersion": 2
}
```

Full field reference: [manifest-ref.md](cloudron-app-packaging-skill/manifest-ref.md).

## Addons

| Addon | Provides | Key env var |
|-------|----------|-------------|
| `localstorage` | Writable `/app/data` + backup | -- |
| `mysql` | MySQL 8.0 | `CLOUDRON_MYSQL_URL` |
| `postgresql` | PostgreSQL 14.9 | `CLOUDRON_POSTGRESQL_URL` |
| `mongodb` | MongoDB 8.0 | `CLOUDRON_MONGODB_URL` |
| `redis` | Redis 8.4 (persistent) | `CLOUDRON_REDIS_URL` |
| `ldap` / `oidc` | LDAP v3 / OpenID Connect auth | `CLOUDRON_LDAP_URL` / `CLOUDRON_OIDC_DISCOVERY_URL` |
| `sendmail` / `recvmail` | Outgoing SMTP / Incoming IMAP | `CLOUDRON_MAIL_SMTP_SERVER` / `CLOUDRON_MAIL_IMAP_SERVER` |
| `proxyauth` | Auth wall | -- |
| `scheduler` | Cron tasks | -- |
| `tls` | App certificate files | `/etc/certs/tls_cert.pem` |
| `docker` | Create containers (restricted) | `CLOUDRON_DOCKER_HOST` |

Full env var lists and options: [addons-ref.md](cloudron-app-packaging-skill/addons-ref.md).

## Stack Notes

- **Apache** — Disable default sites, `Listen 8000`, errors to stderr, `exec /usr/sbin/apache2 -DFOREGROUND`
- **Nginx** — `/run/` for temp paths (`client_body_temp_path`, `proxy_temp_path`). Run with supervisor.
- **PHP** — Sessions to `/run/php/sessions` via symlink
- **Java** — Read cgroup memory limit, set `-XX:MaxRAM`

## Debugging

```bash
cloudron logs [-f]       # view/follow logs
cloudron exec            # shell into app
cloudron debug           # pause app (read-write fs)
cloudron debug --disable # exit debug mode
```

## Examples

All published apps are open source: https://git.cloudron.io/packages — browse by framework: [PHP](https://git.cloudron.io/explore/projects?tag=php) | [Node](https://git.cloudron.io/explore/projects?tag=node) | [Python](https://git.cloudron.io/explore/projects?tag=python) | [Ruby/Rails](https://git.cloudron.io/explore/projects?tag=rails) | [Java](https://git.cloudron.io/explore/projects?tag=java) | [Go](https://git.cloudron.io/explore/projects?tag=go) | [Rust](https://git.cloudron.io/explore/projects?tag=rust)
