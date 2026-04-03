---
description: Reference guide for using git.cloudron.io to study Cloudron app packaging patterns
mode: reference
tools:
  read: true
  bash: true
  webfetch: true
---

# Using git.cloudron.io as Reference

https://git.cloudron.io/ — 200+ official Cloudron app packages; authoritative source for real-world packaging patterns.

## Recommended Reference Apps

| Use Case | Reference App | Why |
|----------|---------------|-----|
| **Node.js + nginx** | [ghost-app](https://git.cloudron.io/packages/ghost-app) | Clean supervisor setup, nginx proxy |
| **PHP + nginx** | [nextcloud-app](https://git.cloudron.io/packages/nextcloud-app) | Complex PHP app, cron, background jobs |
| **PHP + Apache** | [wordpress-app](https://git.cloudron.io/packages/wordpress-app) | Apache config, plugin handling |
| **Python + nginx** | [synapse-app](https://git.cloudron.io/packages/synapse-app) | Python virtualenv, complex config |
| **Go binary** | [vikunja-app](https://git.cloudron.io/packages/vikunja-app) | Simple Go app with nginx frontend |
| **Java/JVM** | [metabase-app](https://git.cloudron.io/packages/metabase-app) | JVM memory tuning, startup scripts |
| **Ruby/Rails** | [discourse-app](https://git.cloudron.io/packages/discourse-app) | Complex Rails app, sidekiq workers |
| **Multi-process** | [peertube-app](https://git.cloudron.io/packages/peertube-app) | Supervisor with multiple workers |
| **LDAP/OIDC auth** | [grafana-app](https://git.cloudron.io/packages/grafana-app) | Auth integration patterns |
| **Media handling** | [jellyfin-app](https://git.cloudron.io/packages/jellyfin-app) | Large file handling, transcoding |

## Key Files to Study

In any reference package:

1. **CloudronManifest.json** — addon requirements, memory limits, health check path
2. **Dockerfile** — base image choice, build steps, file permissions
3. **start.sh** — initialization sequence, config injection, symlink patterns
4. **nginx/*.conf** or **apache/*.conf** — web server configuration
5. **supervisor/*.conf** — multi-process orchestration (if used)
6. **CHANGELOG.md** — version history and migration patterns

## Finding Apps by Technology

| Technology | URL | Count |
|------------|-----|-------|
| PHP | https://git.cloudron.io/explore/projects/topics/php | 21+ |
| Go | https://git.cloudron.io/explore/projects/topics/go | 11+ |
| Node.js | https://git.cloudron.io/explore/projects/topics/node | 10+ |
| Java | https://git.cloudron.io/explore/projects/topics/java | 10+ |
| Python | https://git.cloudron.io/explore/projects/topics/python | 6+ |
| Ruby/Rails | https://git.cloudron.io/explore/projects/topics/rails | 4+ |
| nginx | https://git.cloudron.io/explore/projects/topics/nginx | 6+ |
| Apache | https://git.cloudron.io/explore/projects/topics/apache | 4+ |
| Supervisor | https://git.cloudron.io/explore/projects/topics/supervisor | 2+ |

All topics: https://git.cloudron.io/explore/projects/topics

**Common patterns**: `gosu cloudron:cloudron` (privilege drop) · `ln -sfn /app/data` (writable symlinks) · `CLOUDRON_POSTGRESQL_` (DB config) · `supervisord.conf` (multi-process) · `envsubst` (config templating)

## Repository Groups

| Group | URL | Purpose |
|-------|-----|---------|
| `packages` | https://git.cloudron.io/packages | Official app packages (200+ apps) |
| `playground` | https://git.cloudron.io/playground | Incubator for new/experimental packages |
| `platform` | https://git.cloudron.io/platform | Cloudron platform code (box, base images) |
| `docs` | https://git.cloudron.io/docs | Official documentation source |
| `apps` | https://git.cloudron.io/apps | Apps developed by Cloudron.io team |
| `utils` | https://git.cloudron.io/utils | Tools and utilities |

## Cloning for Local Study

```bash
git clone https://git.cloudron.io/packages/ghost-app.git

# Sparse checkout for specific files only
git clone --filter=blob:none --sparse https://git.cloudron.io/packages/ghost-app.git
cd ghost-app
git sparse-checkout set start.sh Dockerfile CloudronManifest.json
```

## GitLab API

```bash
# List all packages
curl -s "https://git.cloudron.io/api/v4/groups/packages/projects?per_page=100"

# Filter by topic
curl -s "https://git.cloudron.io/api/v4/projects?topic=php&per_page=20"
curl -s "https://git.cloudron.io/api/v4/projects?topic=supervisor"
curl -s "https://git.cloudron.io/api/v4/projects?topic=proxyAuth"

# File tree and raw content
curl -s "https://git.cloudron.io/api/v4/projects/packages%2Fghost-app/repository/tree"
curl -s "https://git.cloudron.io/api/v4/projects/packages%2Fghost-app/repository/files/start.sh/raw?ref=master"

# Code search within a repo (auth required for some endpoints)
curl -s "https://git.cloudron.io/api/v4/projects/packages%2Fghost-app/search?scope=blobs&search=supervisord"

# Browse recently updated: https://git.cloudron.io/explore/projects?sort=latest_activity_desc
```
