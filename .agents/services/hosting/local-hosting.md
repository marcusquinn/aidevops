---
description: Local development hosting — dnsmasq + Traefik + mkcert + port registry
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
---

# Local Hosting — localdev System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary CLI**: `localdev-helper.sh [run|init|add|rm|branch|db|list|status|help]`
- **Legacy CLI**: `localhost-helper.sh [check-port|find-port|list-ports|kill-port|generate-cert|setup-dns|setup-proxy|create-app|start-mcp]`
- **Port registry**: `~/.local-dev-proxy/ports.json` (range: 3100-3999)
- **Certs**: `~/.local-ssl-certs/` | **Routes**: `~/.local-dev-proxy/conf.d/`
- **Traefik**: `~/.local-dev-proxy/traefik.yml` | **Dashboard**: `http://localhost:8080`
- **Shared Postgres**: `local-postgres` container on port 5432

```bash
localdev-helper.sh init          # One-time: dnsmasq, resolver, Traefik conf.d (sudo)
cd ~/Git/myapp
localdev-helper.sh run npm run dev
# → Auto-registers myapp (cert, route, /etc/hosts, port 3100) → https://myapp.local
localdev-helper.sh add myapp    # Manual: cert + route + /etc/hosts + port
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
Browser → /etc/hosts (127.0.0.1 myapp.local)
        → Traefik (Docker, 80/443) — TLS via mkcert certs
        → http://host.docker.internal:{port} — your app
```

| Component | Role | Config |
|-----------|------|--------|
| **/etc/hosts** | `.local` mapping for browsers (mDNS intercepts resolver) | `/etc/hosts` |
| **dnsmasq** | Wildcard `*.local` → `127.0.0.1` (CLI tools only) | `$(brew --prefix)/etc/dnsmasq.conf` |
| **macOS resolver** | Routes `.local` to dnsmasq for CLI | `/etc/resolver/local` |
| **Traefik v3.3** | Reverse proxy, TLS termination | `~/.local-dev-proxy/traefik.yml` |
| **mkcert** | Browser-trusted wildcard certs | `~/.local-ssl-certs/` |
| **Port registry** | app-port-domain mappings, collision detection | `~/.local-dev-proxy/ports.json` |

**DNS:** macOS reserves `.local` for mDNS. Browsers use `/etc/hosts` → mDNS (intercepts resolver, never reached). `localdev add` always writes `/etc/hosts`. dnsmasq handles wildcard subdomains for CLI only. Future: `.test` (RFC 6761) avoids conflict but is breaking.

### Port Registry Format

```json
{
  "apps": {
    "myapp": {
      "port": 3100, "domain": "myapp.local", "added": "2026-01-15T10:30:00Z",
      "branches": { "feature-login": { "port": 3101, "subdomain": "feature-login.myapp.local" } }
    }
  }
}
```

## CLI — localdev-helper.sh

**run** — Zero-config wrapper: auto-registers, resolves port, injects `PORT`/`HOST`, execs command.

```bash
localdev-helper.sh run [--name <name>] [--port <port>] [--no-host] <command...>
# Name inference: --name → package.json name → git repo basename → dir basename
# In worktree → auto-creates branch subdomain (e.g. https://bugfix-fix.myapp.local)
```

**add / rm**

```bash
localdev-helper.sh add <name> [port]   # cert + route + /etc/hosts + port → https://{name}.local
localdev-helper.sh rm <name>           # removes all resources
```

**branch**

```bash
localdev-helper.sh branch <app> <branch> [port]   # add branch subdomain
localdev-helper.sh branch rm <app> <branch>        # remove
localdev-helper.sh branch list [app]               # list
# Branch names sanitised (slashes→hyphens, lowercase). Wildcard cert covers *.myapp.local.
```

**db** — Shared Postgres via `local-postgres` Docker container.

```bash
localdev-helper.sh db start|stop|status
localdev-helper.sh db create|drop <dbname> [-f]
localdev-helper.sh db list
localdev-helper.sh db url <dbname>   # → postgresql://postgres:localdev@localhost:5432/{dbname}
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `LOCALDEV_PG_IMAGE` | `postgres:17-alpine` | Docker image |
| `LOCALDEV_PG_PORT` | `5432` | Host port |
| `LOCALDEV_PG_USER` | `postgres` | User |
| `LOCALDEV_PG_PASSWORD` | `localdev` | Password |
| `LOCALDEV_PG_DATA` | `~/.local-dev-proxy/pgdata` | Data dir |

Hyphens in DB names auto-converted to underscores.

**list / status**

```bash
localdev-helper.sh list    # Dashboard: NAME, URL, PORT, CERT, PROC, PROCESS
localdev-helper.sh status  # Health: [OK] healthy [--] down [!!] missing [!?] partial
```

## CLI — localhost-helper.sh (Legacy)

```bash
localhost-helper.sh check-port <port> | find-port [start] | list-ports | kill-port <port>
localhost-helper.sh generate-cert <domain>
localhost-helper.sh create-app <name> <domain> <port> [ssl] [type]
localhost-helper.sh start-mcp | stop-mcp | test-mcp | mcp-query "<sql>"
```

## OrbStack / Docker

OrbStack preferred over Docker Desktop. Traefik uses `host.docker.internal` for host ports.

```bash
docker network create local-dev   # auto-created by localdev init or db start
```

**Traefik Docker Compose** — `~/.local-dev-proxy/docker-compose.yml`: `traefik:v3.3` container (`local-traefik`), ports 80/443/8080, mounts `traefik.yml`, `conf.d/`, `~/.local-ssl-certs/` read-only, on `local-dev` external network.

## Stack-Specific Guidance

| Stack | Pattern |
|-------|---------|
| **Next.js** | `PORT=3100 npm run dev` or `"dev": "next dev --port ${PORT:-3000}"` |
| **Vite** | `npx vite --port 3100` or `server: { port: 3100 }` in `vite.config.ts` |
| **Rails** | `rails server -p 3100` |
| **Django** | `python manage.py runserver 0.0.0.0:3100` |
| **Go** | `port := os.Getenv("PORT")` |
| **Laravel** | `php artisan serve --port=3100` |
| **Bun** | `PORT=3100 bun run dev` |

**Next.js stale lock (16+):** `rm -f .next/dev/lock && PORT=3100 npm run dev`
Or: `"dev": "rm -f .next/dev/lock && next dev --port ${PORT:-3000}"`

**Turborepo quirks:**

1. Port may be hardcoded in `apps/web/package.json` — match registry
2. `allowedDevOrigins: ["myapp.local"]` required in `next.config.ts` (Next.js 15+)
3. `with-env` loads `.env.local` from monorepo root — place `URL`/`DATABASE_URL` there
4. Skip `localdev db start` if project has own `docker-compose.yml` on port 5432
5. Stale lock: `rm -f apps/web/.next/dev/lock && pnpm dev:web`

**Docker Compose projects:** Map to localdev port (`"3100:3000"`) and join `local-dev` network.

**LocalWP coexistence:** `localdev add` checks for `#Local Site` collisions and rejects conflicts. `localdev list` shows both. Sites config: `~/Library/Application Support/Local/sites.json`.

## Database Patterns

```bash
localdev db create myapp && DATABASE_URL="$(localdev-helper.sh db url myapp)"
localdev db create myapp-feature-auth   # branch-isolated (avoid schema conflicts)
localdev db drop myapp-feature-auth --force   # cleanup after merge
# Custom Postgres version: own docker-compose.yml on port 5433:5432, join local-dev network
```

## Troubleshooting

**DNS** — `https://myapp.local` doesn't resolve:

```bash
grep 'myapp.local' /etc/hosts   # expected: 127.0.0.1 myapp.local *.myapp.local # localdev: myapp
localdev-helper.sh add myapp    # idempotent — safe to re-run
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
dscacheutil -q host -a name myapp.local   # should show ip_address: 127.0.0.1
# LocalWP conflict: check /etc/hosts for #Local Site entry on same domain
```

**Certificates:**

```bash
ls -la ~/.local-ssl-certs/myapp.local+1.pem && mkcert -install
cd ~/.local-ssl-certs && mkcert myapp.local "*.myapp.local"
docker exec local-traefik ls /certs/
```

**Port conflicts:**

```bash
lsof -i :3100 && cat ~/.local-dev-proxy/ports.json | jq '.apps'
localhost-helper.sh kill-port 3100 && localdev-helper.sh list
```

**Traefik:**

```bash
docker ps | grep local-traefik
cd ~/.local-dev-proxy && docker compose up -d && docker logs local-traefik --tail 50
ls ~/.local-dev-proxy/conf.d/myapp.yml && docker compose restart
```

**Shared Postgres:**

```bash
localdev-helper.sh db status && localdev-helper.sh db start
docker exec local-postgres pg_isready -U postgres
psql "postgresql://postgres:localdev@localhost:5432/postgres" -c "SELECT 1"
# Port conflict: LOCALDEV_PG_PORT=5433 localdev-helper.sh db start
```

## Prerequisites

```bash
brew install dnsmasq mkcert && mkcert -install
brew install orbstack   # or Docker Desktop
localdev-helper.sh init
```

## Tool-Specific: App Store Connect (asc-web)

```bash
# asc web-server binds --port AND --port+1 — leave gap of 3+
localdev-helper.sh add asc-web && localdev-helper.sh add asc-editor 3112
ASC_PORT=$(jq -r '.apps["asc-web"].port' ~/.local-dev-proxy/ports.json)
nohup asc web-server --port "$ASC_PORT" > /tmp/asc-web.log 2>&1 &
EDITOR_PORT=$(jq -r '.apps["asc-editor"].port' ~/.local-dev-proxy/ports.json)
nohup npx -y http-server ~/.asc/web/homepage -p "$EDITOR_PORT" --silent > /tmp/asc-editor.log 2>&1 &
# → https://asc-web.local | https://asc-editor.local
```

## File Locations

All under `~/.local-dev-proxy/`: `traefik.yml` (static config), `docker-compose.yml`, `conf.d/` (per-app routes, hot-reloaded), `ports.json` (registry), `pgdata/` (Postgres data), `backup/` (init migration). Certs: `~/.local-ssl-certs/`. System: `/etc/resolver/local`, `$(brew --prefix)/etc/dnsmasq.conf`.

## Legacy vs Current

`localhost-helper.sh` (legacy): ports 3000-9999, single `dynamic.yml`, Traefik v2.10, no port registry/branch subdomains/db management/LocalWP detection, manual init. `localdev-helper.sh` (current): ports 3100-3999, `conf.d/` hot-reload, Traefik v3.3, `ports.json` + collision detection, `branch`/`db` commands, `sites.json` + `/etc/hosts` LocalWP check, single `init` command.
