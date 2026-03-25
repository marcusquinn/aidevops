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

- **Purpose**: Production-like local development with `.local` domains, HTTPS, and port management
- **Primary CLI**: `localdev-helper.sh [run|init|add|rm|branch|db|list|status|help]`
- **Legacy CLI**: `localhost-helper.sh [check-port|find-port|list-ports|kill-port|generate-cert|setup-dns|setup-proxy|create-app|start-mcp]`
- **Port registry**: `~/.local-dev-proxy/ports.json`
- **Certs**: `~/.local-ssl-certs/`
- **Routes**: `~/.local-dev-proxy/conf.d/`
- **Traefik config**: `~/.local-dev-proxy/traefik.yml`
- **Docker Compose**: `~/.local-dev-proxy/docker-compose.yml`
- **Shared Postgres**: `local-postgres` container on port 5432

**Zero-config workflow (recommended):**

```bash
# One-time system setup (dnsmasq, resolver, Traefik conf.d)
localdev-helper.sh init

# In any project directory — auto-registers, injects PORT, runs command
cd ~/Git/myapp
localdev-helper.sh run npm run dev
# → Auto-registers myapp (cert, Traefik route, /etc/hosts, port 3100)
# → Sets PORT=3100 HOST=0.0.0.0
# → https://myapp.local just works
```

**Manual workflow:**

```bash
localdev-helper.sh add myapp   # cert + Traefik route + /etc/hosts + port 3100
# → https://myapp.local on auto-assigned port (3100-3999)
```

**Why `.local` + SSL + port management?**

| Problem | Solution | Why it matters |
|---------|----------|----------------|
| Port conflicts | Port registry (3100-3999) | No "address already in use" errors |
| Password managers fail | SSL via Traefik + mkcert | 1Password/Bitwarden require HTTPS to autofill |
| Inconsistent URLs | `.local` domains via dnsmasq | `myapp.local` instead of `localhost:3847` |
| Browser security warnings | mkcert trusted certs | No "proceed anyway" clicks |

<!-- AI-CONTEXT-END -->

## Architecture

```text
Browser request: https://myapp.local
        |
        v
  /etc/hosts (127.0.0.1 myapp.local)
    ← REQUIRED for .local in browsers (mDNS intercepts /etc/resolver)
        |
        v
  Traefik (Docker, ports 80/443/8080)
    reads conf.d/*.yml (file provider, watch: true)
    terminates TLS using mkcert certs from ~/.local-ssl-certs/
        |
        v
  http://host.docker.internal:{port}
    → Your app listening on the registered port
```

### Component Roles

| Component | Role | Config location |
|-----------|------|-----------------|
| **/etc/hosts** | **Primary**: maps `.local` domains to `127.0.0.1` for browsers | `/etc/hosts` |
| **dnsmasq** | Wildcard `*.local` → `127.0.0.1` (CLI tools only) | `$(brew --prefix)/etc/dnsmasq.conf` |
| **macOS resolver** | Routes `.local` to dnsmasq for CLI tools | `/etc/resolver/local` |
| **Traefik v3.3** | Reverse proxy, TLS termination, routing | `~/.local-dev-proxy/traefik.yml` |
| **mkcert** | Generates browser-trusted wildcard certs | `~/.local-ssl-certs/` |
| **Port registry** | Tracks app→port→domain mappings | `~/.local-dev-proxy/ports.json` |
| **conf.d/** | Per-app Traefik route files (hot-reloaded) | `~/.local-dev-proxy/conf.d/` |

### DNS Resolution and the .local mDNS Problem

macOS reserves `.local` for mDNS (Bonjour/multicast DNS). This creates a resolution conflict:

```text
Browsers (Chrome, Safari, Firefox):
  1. /etc/hosts          ← WORKS — only reliable method for .local
  2. mDNS multicast      ← INTERCEPTS .local before resolver files
  3. /etc/resolver/local  ← NEVER REACHED for .local in browsers

CLI tools (dig, curl, etc.):
  1. /etc/hosts           ← Checked first
  2. /etc/resolver/local  ← Works — routes to dnsmasq
  3. Upstream DNS         ← External domains
```

**Why `localdev add` always writes `/etc/hosts`**: Browsers use the system resolver which sends `.local` queries to mDNS before consulting resolver files. Only `/etc/hosts` entries reliably override mDNS for `.local` domains in browsers. dnsmasq is still useful for wildcard subdomain resolution in CLI tools.

> **Future consideration**: `.test` (RFC 6761) and `.localhost` avoid the mDNS conflict entirely. Switching TLD would be a breaking change but would eliminate the `/etc/hosts` requirement.

### Port Registry Format

```json
{
  "apps": {
    "myapp": {
      "port": 3100,
      "domain": "myapp.local",
      "added": "2026-01-15T10:30:00Z",
      "branches": {
        "feature-login": {
          "port": 3101,
          "subdomain": "feature-login.myapp.local",
          "added": "2026-01-16T14:00:00Z"
        }
      }
    }
  }
}
```

Port range: **3100-3999** (auto-assigned). Ports are checked against both the registry and OS-level `lsof` to avoid conflicts.

## CLI Reference — localdev-helper.sh

### init

One-time system setup. Configures dnsmasq, macOS resolver, and migrates Traefik to conf.d directory provider. Requires `sudo`. Idempotent.

```bash
localdev-helper.sh init
```

Performs: check prerequisites → add dnsmasq wildcard → create `/etc/resolver/local` → migrate Traefik to `conf.d/` → preserve existing routes → restart Traefik.

### run

Zero-config dev server wrapper. Auto-registers the project if needed, resolves the correct port, injects `PORT` and `HOST`, and execs the command.

```bash
localdev-helper.sh run [--name <name>] [--port <port>] [--no-host] <command...>
```

```bash
# In ~/Git/myapp/ — auto-registers and starts
localdev-helper.sh run npm run dev

# In a worktree ~/Git/myapp-bugfix-fix-thing/ — auto-creates branch subdomain
localdev-helper.sh run npm run dev
# → https://bugfix-fix-thing.myapp.local on auto-assigned port

localdev-helper.sh run --name my-custom-name pnpm dev
localdev-helper.sh run --port 3200 bun run dev
```

Project name inference priority: `--name` flag → `package.json` `name` field → git repo basename → directory basename.

### add

Register a new app with cert, Traefik route, `/etc/hosts` entry, and port assignment.

```bash
localdev-helper.sh add <name> [port]
```

Performs: collision detection → auto-assign port → generate mkcert wildcard cert → create `conf.d/{name}.yml` → add `/etc/hosts` entry → register in `ports.json`.

Result: `https://{name}.local` routes to `http://localhost:{port}`

### rm

Remove an app and all its resources (reverses `add`).

```bash
localdev-helper.sh rm <name>
```

Removes: all branch routes, Traefik route file, mkcert cert files, `/etc/hosts` entry, registry entry.

### branch

Create branch-specific subdomain routes for worktrees/feature branches.

```bash
localdev-helper.sh branch <app> <branch> [port]   # Add branch subdomain
localdev-helper.sh branch rm <app> <branch>        # Remove branch route
localdev-helper.sh branch list [app]               # List branch routes
```

Branch names are sanitised for DNS: slashes become hyphens, lowercase, alphanumeric only. No new cert needed — the wildcard cert from `add` covers `*.myapp.local` subdomains.

### db

Shared Postgres database management via a `local-postgres` Docker container.

```bash
localdev-helper.sh db start              # Ensure container is running
localdev-helper.sh db stop               # Stop container
localdev-helper.sh db create <dbname>    # Create database
localdev-helper.sh db drop <dbname> -f   # Drop database (requires --force)
localdev-helper.sh db list               # List all databases with URLs
localdev-helper.sh db url <dbname>       # Output connection string
localdev-helper.sh db status             # Container and database status
```

Default configuration (override via environment variables):

| Variable | Default | Purpose |
|----------|---------|---------|
| `LOCALDEV_PG_IMAGE` | `postgres:17-alpine` | Docker image |
| `LOCALDEV_PG_PORT` | `5432` | Host port |
| `LOCALDEV_PG_USER` | `postgres` | Postgres user |
| `LOCALDEV_PG_PASSWORD` | `localdev` | Postgres password |
| `LOCALDEV_PG_DATA` | `~/.local-dev-proxy/pgdata` | Data directory |

Database names with hyphens are auto-converted to underscores. Connection string: `postgresql://postgres:localdev@localhost:5432/{dbname}`

### list / status

```bash
localdev-helper.sh list    # Dashboard: NAME, URL, PORT, CERT, PROC, PROCESS
localdev-helper.sh status  # Infrastructure health check for all components
```

Legend: `[OK]` = healthy, `[--]` = down, `[!!]` = missing, `[!?]` = partial

## CLI Reference — localhost-helper.sh (Legacy)

For new projects, prefer `localdev-helper.sh`.

```bash
localhost-helper.sh check-port <port>     # Check availability, suggest alternative
localhost-helper.sh find-port [start]     # Find next available port (default: 3000)
localhost-helper.sh list-ports            # List common dev ports in use
localhost-helper.sh kill-port <port>      # Kill process on port
localhost-helper.sh setup-dns             # Configure dnsmasq (use localdev init instead)
localhost-helper.sh setup-proxy           # Setup Traefik (use localdev init instead)
localhost-helper.sh generate-cert <domain> # Generate mkcert cert
localhost-helper.sh create-app <name> <domain> <port> [ssl] [type]
localhost-helper.sh start-mcp             # Start LocalWP MCP server (port 8085)
localhost-helper.sh stop-mcp / test-mcp / mcp-query "<sql>"
```

## LocalWP Coexistence

LocalWP adds entries like `192.168.95.100 mysite.local #Local Site` to `/etc/hosts`. The localdev system coexists safely:

- LocalWP domains always take precedence (by design)
- `localdev add` checks for LocalWP collisions and rejects conflicting domains
- `localdev list` shows both localdev and LocalWP sites in one dashboard
- LocalWP sites.json: `~/Library/Application Support/Local/sites.json`

## OrbStack / Docker Integration

Traefik runs as a Docker container using `host.docker.internal` to reach host-bound app ports. OrbStack is preferred over Docker Desktop (lower memory footprint).

```bash
# Docker network (created automatically by localdev init or db start)
docker network create local-dev
```

**Traefik Docker Compose** (`~/.local-dev-proxy/docker-compose.yml`):

```yaml
services:
  traefik:
    image: traefik:v3.3
    container_name: local-traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./conf.d:/etc/traefik/conf.d:ro
      - ~/.local-ssl-certs:/certs:ro
    networks:
      - local-dev

networks:
  local-dev:
    external: true
```

**Traefik dashboard**: `http://localhost:8080`

## Database Management Patterns

```bash
# Per-project database
localdev db create myapp
DATABASE_URL="$(localdev-helper.sh db url myapp)"

# Branch-isolated database (avoid schema conflicts)
localdev db create myapp-feature-auth
# → postgresql://postgres:localdev@localhost:5432/myapp_feature_auth
localdev db drop myapp-feature-auth --force  # cleanup after merge
```

For projects needing a specific Postgres version, use their own `docker-compose.yml` with a different host port (e.g., `5433:5432`) and join the `local-dev` network.

## Stack-Specific Guidance

After `localdev add` assigns a port, configure your app to use it:

| Stack | Pattern |
|-------|---------|
| **Next.js** | `PORT=3100 npm run dev` or `"dev": "next dev --port ${PORT:-3000}"` |
| **Vite** | `npx vite --port 3100` or `server: { port: 3100 }` in `vite.config.ts` |
| **Rails** | `rails server -p 3100` |
| **Django** | `python manage.py runserver 0.0.0.0:3100` |
| **Go** | `port := os.Getenv("PORT")` |
| **Laravel** | `php artisan serve --port=3100` |
| **Bun** | `PORT=3100 bun run dev` |

**Next.js stale lock file (Next.js 16+):** Ungraceful shutdowns leave `.next/dev/lock` behind, blocking restart with `Unable to acquire lock`. Port-killing alone does not remove it.

```bash
rm -f .next/dev/lock && PORT=3100 npm run dev
# Recommended: add to package.json
"dev": "rm -f .next/dev/lock && next dev --port ${PORT:-3000}"
```

### Turbostarter / Turborepo Monorepo

Key quirks discovered during webapp migration:

1. **Port hardcoded in `apps/web/package.json`** — use the same port in localdev registry
2. **`allowedDevOrigins` required in `next.config.ts`** (Next.js 15+):
   ```typescript
   allowedDevOrigins: ["myapp.local", "myapp.local:3000", "localhost:3000"]
   ```
3. **`with-env` script** loads `.env.local` from monorepo root — place `URL` and `DATABASE_URL` there
4. **Postgres**: if project has its own `docker-compose.yml` with port 5432, skip `localdev db start`
5. **Stale lock**: `rm -f apps/web/.next/dev/lock && pnpm dev:web`

### Docker Compose Projects

```yaml
services:
  app:
    build: .
    ports:
      - "3100:3000"  # Map to localdev-assigned port
    networks:
      - local-dev

networks:
  local-dev:
    external: true
```

## Troubleshooting

### DNS Resolution

**Symptom**: `https://myapp.local` doesn't resolve in browser.

**Most likely cause**: Missing `/etc/hosts` entry.

```bash
grep 'myapp.local' /etc/hosts
# Should show: 127.0.0.1 myapp.local *.myapp.local # localdev: myapp

localdev-helper.sh add myapp  # Re-running add is safe (idempotent)
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
dscacheutil -q host -a name myapp.local  # Should show: ip_address: 127.0.0.1
```

**LocalWP conflict**: If a domain resolves to a LocalWP IP, check `/etc/hosts` for a conflicting `#Local Site` entry.

### Certificate Issues

```bash
ls -la ~/.local-ssl-certs/myapp.local+1.pem
mkcert -install  # Verify CA is installed
cd ~/.local-ssl-certs && mkcert myapp.local "*.myapp.local"  # Regenerate
docker exec local-traefik ls /certs/  # Verify Traefik can read cert
```

### Port Conflicts

```bash
lsof -i :3100                          # Check what's using a port
cat ~/.local-dev-proxy/ports.json | jq '.apps'
localhost-helper.sh kill-port 3100     # Kill orphaned process
localdev-helper.sh list                # Check all registered ports
```

### Traefik Issues

```bash
docker ps | grep local-traefik
cd ~/.local-dev-proxy && docker compose up -d
docker logs local-traefik --tail 50
ls ~/.local-dev-proxy/conf.d/myapp.yml
# Open http://localhost:8080 for Traefik dashboard
cd ~/.local-dev-proxy && docker compose restart
```

### Shared Postgres

```bash
localdev-helper.sh db status
localdev-helper.sh db start
docker exec local-postgres pg_isready -U postgres
psql "postgresql://postgres:localdev@localhost:5432/postgres" -c "SELECT 1"
# Port conflict: LOCALDEV_PG_PORT=5433 localdev-helper.sh db start
```

## Prerequisites

```bash
brew install dnsmasq mkcert
mkcert -install  # Install CA into system trust store (one-time)
brew install orbstack  # Or Docker Desktop
localdev-helper.sh init
```

## Tool-Specific Examples

### App Store Connect Web Dashboard (asc-web)

```bash
# Register two apps (leave a port gap of 3+ — asc web-server binds --port AND --port+1)
localdev-helper.sh add asc-web          # e.g. port 3109
localdev-helper.sh add asc-editor 3112  # skip 3110-3111

ASC_PORT=$(jq -r '.apps["asc-web"].port' ~/.local-dev-proxy/ports.json)
nohup asc web-server --port "$ASC_PORT" > /tmp/asc-web.log 2>&1 &

EDITOR_PORT=$(jq -r '.apps["asc-editor"].port' ~/.local-dev-proxy/ports.json)
nohup npx -y http-server ~/.asc/web/homepage -p "$EDITOR_PORT" --silent > /tmp/asc-editor.log 2>&1 &

# → https://asc-web.local/command-center/ | /console/ | https://asc-editor.local/editor/
```

## File Locations

| Path | Purpose |
|------|---------|
| `~/.local-dev-proxy/` | Traefik config, port registry, Postgres data |
| `~/.local-dev-proxy/traefik.yml` | Traefik static config |
| `~/.local-dev-proxy/docker-compose.yml` | Traefik Docker Compose |
| `~/.local-dev-proxy/conf.d/` | Per-app Traefik route files |
| `~/.local-dev-proxy/ports.json` | Port registry (apps + branches) |
| `~/.local-dev-proxy/pgdata/` | Shared Postgres data directory |
| `~/.local-dev-proxy/backup/` | Backups from init migration |
| `~/.local-ssl-certs/` | mkcert certificate and key files |
| `/etc/resolver/local` | macOS resolver for `.local` domains |
| `$(brew --prefix)/etc/dnsmasq.conf` | dnsmasq configuration |

## Legacy Context

Key differences between legacy and current:

| Aspect | localhost-helper.sh (legacy) | localdev-helper.sh (current) |
|--------|------------------------------|------------------------------|
| Port range | 3000-9999 | 3100-3999 |
| Traefik config | Single `dynamic.yml` | `conf.d/` directory (hot-reload) |
| Traefik version | v2.10 | v3.3 |
| Port registry | None (manual tracking) | `ports.json` with collision detection |
| Branch subdomains | Not supported | `branch` command with auto-port |
| Database management | Not supported | `db` command (shared Postgres) |
| LocalWP detection | Basic directory check | `sites.json` parsing + `/etc/hosts` check |
| Collision detection | None | Full (LocalWP, registry, OS port) |
| Init automation | Manual steps | Single `init` command |
