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
- **Primary CLI**: `localdev-helper.sh [init|add|rm|branch|db|list|status|help]`
- **Legacy CLI**: `localhost-helper.sh [check-port|find-port|list-ports|kill-port|generate-cert|setup-dns|setup-proxy|create-app|start-mcp]`
- **Port registry**: `~/.local-dev-proxy/ports.json`
- **Certs**: `~/.local-ssl-certs/`
- **Routes**: `~/.local-dev-proxy/conf.d/`
- **Traefik config**: `~/.local-dev-proxy/traefik.yml`
- **Docker Compose**: `~/.local-dev-proxy/docker-compose.yml`
- **Shared Postgres**: `local-postgres` container on port 5432

**Standard workflow — register a new project:**

```bash
# One-time system setup (dnsmasq, resolver, Traefik conf.d)
localdev-helper.sh init

# Register app: generates cert, creates Traefik route, assigns port
localdev-helper.sh add myapp

# Result: https://myapp.local on auto-assigned port (3100-3999)
# Start your app on the assigned port and access via the .local domain
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
  /etc/resolver/local → dnsmasq (127.0.0.1)
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
| **dnsmasq** | Resolves `*.local` → `127.0.0.1` | `$(brew --prefix)/etc/dnsmasq.conf` |
| **macOS resolver** | Routes `.local` DNS queries to dnsmasq | `/etc/resolver/local` |
| **Traefik v3.3** | Reverse proxy, TLS termination, routing | `~/.local-dev-proxy/traefik.yml` |
| **mkcert** | Generates browser-trusted wildcard certs | `~/.local-ssl-certs/` |
| **Port registry** | Tracks app→port→domain mappings | `~/.local-dev-proxy/ports.json` |
| **conf.d/** | Per-app Traefik route files (hot-reloaded) | `~/.local-dev-proxy/conf.d/` |

### DNS Resolution Order (macOS)

```text
1. /etc/hosts          ← LocalWP entries (#Local Site) win here
2. /etc/resolver/local ← dnsmasq wildcard for .local
3. Upstream DNS        ← External domains
```

This order is critical for LocalWP coexistence: domains in `/etc/hosts` always take precedence over dnsmasq.

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

One-time system setup. Configures dnsmasq, macOS resolver, and migrates Traefik to conf.d directory provider. Requires `sudo`. Idempotent — safe to run multiple times.

```bash
localdev-helper.sh init
```

Performs:

1. Check prerequisites (docker, mkcert, dnsmasq)
2. Add `address=/.local/127.0.0.1` to dnsmasq.conf
3. Create `/etc/resolver/local` with `nameserver 127.0.0.1`
4. Migrate Traefik from single `dynamic.yml` to `conf.d/` directory provider
5. Preserve existing routes (backs up to `~/.local-dev-proxy/backup/`)
6. Restart Traefik if running

### add

Register a new app with cert, Traefik route, and port assignment.

```bash
localdev-helper.sh add <name> [port]
```

- `name`: lowercase alphanumeric + hyphens (e.g., `myapp`, `my-project`)
- `port`: optional, auto-assigned from 3100-3999 if omitted

Performs:

1. Collision detection (LocalWP domains, registry, port)
2. Auto-assign port from 3100-3999 (or validate specified port)
3. Generate mkcert wildcard cert (`*.name.local` + `name.local`)
4. Create Traefik route: `conf.d/{name}.yml`
5. Add `/etc/hosts` fallback if dnsmasq not configured
6. Register in `ports.json`

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
# Add branch subdomain
localdev-helper.sh branch <app> <branch> [port]

# Remove branch route
localdev-helper.sh branch rm <app> <branch>

# List branch routes
localdev-helper.sh branch list [app]
```

Branch names are sanitised for DNS: slashes become hyphens, lowercase, alphanumeric only.

Example:

```bash
localdev-helper.sh branch myapp feature/login
# → https://feature-login.myapp.local on auto-assigned port
```

No new cert needed — the wildcard cert from `add` covers `*.myapp.local` subdomains.

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

Database names with hyphens are auto-converted to underscores for Postgres compatibility (e.g., `myapp-feature-xyz` becomes `myapp_feature_xyz`).

Connection string format: `postgresql://postgres:localdev@localhost:5432/{dbname}`

### list

Unified dashboard showing all local projects, URLs, cert status, process health, LocalWP sites, and shared Postgres.

```bash
localdev-helper.sh list
```

Output columns: NAME, URL, PORT, CERT, PROC, PROCESS

Legend: `[OK]` = healthy, `[--]` = down, `[!!]` = missing, `[!?]` = partial

### status

Infrastructure health check for all localdev components.

```bash
localdev-helper.sh status
```

Checks: dnsmasq config and process, macOS resolver, Traefik conf.d and container, certificates per app, port health per app, LocalWP coexistence, shared Postgres.

## CLI Reference — localhost-helper.sh (Legacy)

The legacy helper provides port management and basic setup functions. For new projects, prefer `localdev-helper.sh`.

```bash
# Port management
localhost-helper.sh check-port <port>     # Check availability, suggest alternative
localhost-helper.sh find-port [start]     # Find next available port (default: 3000)
localhost-helper.sh list-ports            # List common dev ports in use
localhost-helper.sh kill-port <port>      # Kill process on port

# DNS and proxy
localhost-helper.sh setup-dns             # Configure dnsmasq (use localdev init instead)
localhost-helper.sh setup-proxy           # Setup Traefik (use localdev init instead)
localhost-helper.sh generate-cert <domain> # Generate mkcert cert

# App management
localhost-helper.sh create-app <name> <domain> <port> [ssl] [type]

# LocalWP MCP
localhost-helper.sh start-mcp             # Start LocalWP MCP server (port 8085)
localhost-helper.sh stop-mcp              # Stop LocalWP MCP server
```

## LocalWP Coexistence

LocalWP manages WordPress sites with its own DNS entries in `/etc/hosts` (marked with `#Local Site`). The localdev system coexists safely:

**How it works:**

1. LocalWP adds entries like `192.168.95.100 mysite.local #Local Site` to `/etc/hosts`
2. macOS resolves `/etc/hosts` before `/etc/resolver/local`
3. dnsmasq wildcard only handles domains NOT in `/etc/hosts`
4. `localdev add` checks for LocalWP collisions and rejects conflicting domains

**Rules:**

- Never manually add `.local` entries to `/etc/hosts` that conflict with localdev domains
- LocalWP domains always take precedence — this is by design
- Use `localdev list` to see both localdev and LocalWP sites in one dashboard
- LocalWP sites are read-only in the dashboard (managed by LocalWP itself)

**LocalWP sites.json**: `~/Library/Application Support/Local/sites.json` — the dashboard reads this for richer site data (PHP version, MySQL version, ports).

## OrbStack / Docker Integration

localdev uses Docker for Traefik and the shared Postgres container. It works with both Docker Desktop and OrbStack.

**OrbStack specifics:**

- OrbStack provides its own `.orb.local` domains for containers — these are separate from localdev's `.local` domains
- Traefik runs as a Docker container and uses `host.docker.internal` to reach host-bound app ports
- The `local-dev` Docker network is shared between Traefik and the Postgres container
- OrbStack's lower memory footprint makes it preferred over Docker Desktop

**Docker network:**

```bash
# Created automatically by localdev init or db start
docker network create local-dev
```

All localdev containers (Traefik, Postgres) join the `local-dev` network. Project containers can also join this network for direct container-to-container communication.

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

**Traefik dashboard**: `http://localhost:8080` (when Traefik is running).

## Database Management Patterns

### Per-Project Databases

```bash
# Create database for a project
localdev db create myapp
# → postgresql://postgres:localdev@localhost:5432/myapp

# Use in your app's .env
DATABASE_URL="$(localdev-helper.sh db url myapp)"
```

### Branch-Isolated Databases

Create separate databases per feature branch to avoid schema conflicts:

```bash
# Create branch database
localdev db create myapp-feature-auth
# → postgresql://postgres:localdev@localhost:5432/myapp_feature_auth

# When branch is merged, clean up
localdev db drop myapp-feature-auth --force
```

### Project-Specific Postgres

The shared Postgres is for convenience. Projects needing a specific Postgres version should use their own `docker-compose.yml`:

```yaml
services:
  db:
    image: postgres:15-alpine
    ports:
      - "5433:5432"  # Different host port to avoid conflict
    environment:
      POSTGRES_PASSWORD: dev
    networks:
      - local-dev

networks:
  local-dev:
    external: true
```

## Branch Subdomain Workflow

The branch subdomain system enables running multiple versions of an app simultaneously — useful for PR reviews, A/B testing, or parallel feature development.

### Full Workflow

```bash
# 1. Register the main app (one-time)
localdev-helper.sh add myapp
# → https://myapp.local on port 3100

# 2. Create a branch subdomain for a feature
localdev-helper.sh branch myapp feature/user-auth
# → https://feature-user-auth.myapp.local on port 3101

# 3. Start the branch version on the assigned port
cd ~/Git/myapp-feature-user-auth/
PORT=3101 npm run dev

# 4. When done, remove the branch route
localdev-helper.sh branch rm myapp feature-user-auth

# 5. List all branches for an app
localdev-helper.sh branch list myapp
```

### Integration with Git Worktrees

Branch subdomains pair naturally with git worktrees:

```bash
# Create worktree for feature branch
git worktree add ../myapp-feature-login feature/login

# Register branch subdomain
localdev-helper.sh branch myapp feature/login

# Start the worktree's dev server on the assigned port
cd ../myapp-feature-login
PORT=$(localdev-helper.sh branch list myapp | grep feature-login | awk '{print $3}' | sed 's/port://') npm run dev
```

## Stack-Specific Guidance

Different frameworks bind to ports differently. After `localdev add` assigns a port, configure your app accordingly.

### Next.js

```bash
# next dev uses PORT env var
PORT=3100 npm run dev

# Or in package.json scripts
"dev": "next dev --port ${PORT:-3000}"

# Or .env.local
PORT=3100
```

### Vite (Vue, React, Svelte)

```bash
# CLI flag
npx vite --port 3100

# Or vite.config.ts
export default defineConfig({
  server: { port: 3100 }
})

# Or environment variable
VITE_PORT=3100 npx vite --port $VITE_PORT
```

### Ruby on Rails

```bash
# CLI flag
rails server -p 3100

# Or Procfile.dev
web: bin/rails server -p 3100
```

### Django

```bash
# CLI argument
python manage.py runserver 0.0.0.0:3100
```

### Go (net/http)

```go
// Use the assigned port
port := os.Getenv("PORT")
if port == "" {
    port = "3100"
}
http.ListenAndServe(":"+port, handler)
```

### PHP (Laravel)

```bash
# Artisan serve
php artisan serve --port=3100

# Or Laravel Valet (separate system, may conflict — prefer localdev)
```

### Bun

```bash
# Bun uses PORT env var
PORT=3100 bun run dev

# Or in bunfig.toml / code
Bun.serve({ port: 3100 })
```

### Turbostarter / Turborepo Monorepo

Turbostarter (and similar Turborepo-based monorepos) have specific quirks discovered during the awardsapp migration:

**1. Port hardcoded in `apps/web/package.json`** (not via `PORT` env var):

```json
"scripts": {
  "dev": "next dev --port 3100"
}
```

When registering with localdev, use the same port that's hardcoded in the web app's `package.json`. If you need to change the port, update both the localdev registry and the `package.json` script.

**2. `allowedDevOrigins` required in `next.config.ts`** (Next.js 15+):

Next.js 15 blocks cross-origin requests by default. Add your `.local` domain to `allowedDevOrigins`:

```typescript
const config: NextConfig = {
  allowedDevOrigins: [
    "myapp.local",
    "myapp.local:3000",
    "localhost:3000",
  ],
  // ...
};
```

Without this, browser requests from `https://myapp.local` will be blocked with a CORS error.

**3. `with-env` script loads `.env.local` from monorepo root**:

Turbostarter uses `dotenv -c --` (aliased as `with-env`) to inject environment variables:

```bash
# Root package.json
"dev": "pnpm with-env turbo dev"
"dev:web": "pnpm with-env pnpm --filter web dev"
```

Place your `URL` and `DATABASE_URL` in the root `.env.local`:

```bash
URL="https://myapp.local"
NEXT_PUBLIC_URL="https://myapp.local"
DATABASE_URL="postgresql://user:pass@localhost:5432/mydb"
```

**4. Postgres: project-specific container vs shared `local-postgres`**:

Turbostarter projects typically include their own `docker-compose.yml` with a Postgres container. If port 5432 is already allocated by the project's container, `localdev db start` will fail with "port already allocated". This is expected — use the project's own Postgres container and skip `localdev db start`.

```bash
# Start project services (includes Postgres)
pnpm services:start  # or: docker compose up -d

# Verify connectivity
docker exec <project>-db-1 psql -U <user> -d <db> -c '\dt'
```

**5. Start command for development**:

```bash
# From monorepo root — starts all apps via Turborepo
pnpm dev

# Or just the web app
pnpm dev:web

# Or directly in apps/web/
cd apps/web && pnpm dev
```

### Docker Compose Projects

For projects using Docker Compose, expose the app port and let Traefik route to it:

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

**Symptom**: `https://myapp.local` doesn't resolve.

```bash
# Check dnsmasq is running
pgrep -x dnsmasq

# Test DNS resolution
dig myapp.local @127.0.0.1

# Verify resolver file
cat /etc/resolver/local
# Should contain: nameserver 127.0.0.1

# Check dnsmasq config
grep 'address=/.local/' "$(brew --prefix)/etc/dnsmasq.conf"
# Should contain: address=/.local/127.0.0.1

# Restart dnsmasq
sudo brew services restart dnsmasq

# Flush macOS DNS cache
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

**Common cause**: macOS mDNSResponder sometimes caches stale results. Flushing the cache usually resolves it.

**LocalWP conflict**: If a domain resolves to a LocalWP IP instead of 127.0.0.1, check `/etc/hosts` for a conflicting entry.

### Certificate Issues

**Symptom**: Browser shows "not secure" or certificate error.

```bash
# Check cert files exist
ls -la ~/.local-ssl-certs/myapp.local+1.pem
ls -la ~/.local-ssl-certs/myapp.local+1-key.pem

# Verify mkcert CA is installed
mkcert -install

# Regenerate cert
cd ~/.local-ssl-certs && mkcert myapp.local "*.myapp.local"

# Check cert validity
openssl x509 -in ~/.local-ssl-certs/myapp.local+1.pem -text -noout | grep -A2 "Validity"

# Verify Traefik can read the cert
docker exec local-traefik ls /certs/
```

**Common cause**: mkcert CA not installed in system trust store. Run `mkcert -install` (requires sudo on first run).

### Port Conflicts

**Symptom**: "address already in use" or app won't start.

```bash
# Check what's using a port
lsof -i :3100

# Check the port registry
cat ~/.local-dev-proxy/ports.json | jq '.apps'

# Find next available port
localdev-helper.sh add myapp  # Auto-assigns from 3100-3999

# Kill a process on a port (use with caution)
localhost-helper.sh kill-port 3100

# Check all registered ports and their health
localdev-helper.sh list
```

**Common cause**: A previous dev server didn't shut down cleanly. Check with `lsof` and kill the orphaned process.

### Traefik Issues

**Symptom**: Domain resolves but connection refused or 404.

```bash
# Check Traefik is running
docker ps | grep local-traefik

# Start Traefik
cd ~/.local-dev-proxy && docker compose up -d

# Check Traefik logs
docker logs local-traefik --tail 50

# Verify route file exists
ls ~/.local-dev-proxy/conf.d/myapp.yml

# Check Traefik dashboard for route status
# Open http://localhost:8080 in browser

# Restart Traefik (picks up all conf.d changes)
cd ~/.local-dev-proxy && docker compose restart
```

**Common cause**: Traefik not running, or the app isn't listening on the registered port. Traefik routes to `host.docker.internal:{port}` — the app must be listening on that port on the host.

### Shared Postgres

**Symptom**: Can't connect to database.

```bash
# Check container status
localdev-helper.sh db status

# Start if not running
localdev-helper.sh db start

# Check connectivity
docker exec local-postgres pg_isready -U postgres

# View logs
docker logs local-postgres --tail 20

# Test connection from host
psql "postgresql://postgres:localdev@localhost:5432/postgres" -c "SELECT 1"
```

**Common cause**: Container stopped or port 5432 is used by a system Postgres installation. Change the port with `LOCALDEV_PG_PORT=5433 localdev-helper.sh db start`.

## Prerequisites

Install required tools:

```bash
# macOS (Homebrew)
brew install dnsmasq mkcert

# Install mkcert CA into system trust store (one-time)
mkcert -install

# Docker: install OrbStack (preferred) or Docker Desktop
brew install orbstack
```

Then run the one-time setup:

```bash
localdev-helper.sh init
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

The `localhost.md` agent in this directory contains the original localhost development guide. It documents the older `localhost-helper.sh` approach with manual setup steps. For new projects, use `localdev-helper.sh` which automates the full workflow.

Key differences:

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
