---
description: NetBird - Self-hosted WireGuard mesh VPN with SSO, ACLs, and API automation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# NetBird - Self-Hosted Mesh VPN & Zero-Trust Networking

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Self-hosted WireGuard mesh VPN with SSO, MFA, granular ACLs, and REST API
- **Why NetBird over Tailscale**: Fully self-hosted control plane (AGPL), no vendor lock-in, API-first, Terraform provider
- **Install client**: `curl -fsSL https://pkgs.netbird.io/install.sh | sh` (Linux/macOS)
- **CLI**: `netbird` (client control)
- **Admin UI**: `https://netbird.example.com` (self-hosted dashboard)
- **API**: `https://netbird.example.com/api` (REST, documented at docs.netbird.io/api)
- **Docs**: https://docs.netbird.io
- **License**: BSD-3 (client), AGPL-3.0 (management/signal/relay)
- **GitHub**: https://github.com/netbirdio/netbird (22.9k stars, 124 contributors)

**Key Concepts**:

- **Management Server**: Holds network state, distributes peer configs, manages ACLs
- **Signal Server**: Brokers WebRTC ICE candidates for P2P connection setup
- **Relay Server**: Fallback when direct P2P fails (strict NAT, carrier-grade NAT)
- **Setup Key**: Pre-authenticated token for bulk device provisioning (ideal for AI workers)
- **Peer Group**: Logical grouping of devices for ACL rules
- **Network Route**: Advertise subnets reachable through a peer (site-to-site)
- **Private DNS**: Resolve peer names within the mesh (e.g., `build01.netbird.cloud`)

<!-- AI-CONTEXT-END -->

## Architecture Overview

```text
                    +-------------------+
                    |  Management Server |  (network state, ACLs, peer registry)
                    |  Signal Server     |  (WebRTC ICE negotiation)
                    |  Relay Server      |  (TURN fallback for strict NAT)
                    |  Dashboard         |  (admin web UI)
                    +--------+----------+
                             |
              +--------------+--------------+
              |              |              |
         +----+----+   +----+----+   +----+----+
         |  Mac    |   | Linux   |   |  VPS    |
         | Client  |<->| Client  |<->| Client  |   <-- WireGuard P2P mesh
         +---------+   +---------+   +---------+
              |              |              |
         +----+----+   +----+----+   +----+----+
         | Proxmox |   |  Pi     |   | Docker  |
         | Client  |<->| Client  |<->| Client  |
         +---------+   +---------+   +---------+
```

All traffic is peer-to-peer WireGuard. The management server only coordinates -- no data flows through it.

## Self-Hosting the Control Plane

### Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 2 GB | 4 GB |
| Disk | 10 GB | 20 GB |
| Network | Public IP + domain | Static IP preferred |
| Ports | TCP 80, 443 + UDP 3478 | Same |
| OS | Any Linux with Docker | Ubuntu 22.04+ |

### Quickstart (Docker Compose)

```bash
# Set your domain and run the installer
export NETBIRD_DOMAIN=netbird.example.com
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh | bash
```

This deploys:
- `netbird-server` (combined management + signal + relay + STUN)
- `dashboard` (web UI with embedded nginx)
- `traefik` (reverse proxy + Let's Encrypt TLS)

### Port Requirements

| Port | Protocol | Purpose | Proxyable? |
|------|----------|---------|------------|
| 80 | TCP | HTTP / ACME validation | Yes |
| 443 | TCP | HTTPS (dashboard, API, gRPC, relay WebSocket) | Yes |
| 3478 | UDP | STUN (NAT traversal) | **No -- must be exposed directly** |

### Database Options

| Engine | Use Case | Notes |
|--------|----------|-------|
| SQLite (default) | Small deployments (<50 peers) | Zero config, no HA |
| PostgreSQL | Production | Concurrent access, HA-capable |
| MySQL/MariaDB | Production alternative | Same benefits as PostgreSQL |

For Cloudron deployments, use the PostgreSQL addon.

### Identity Provider (IdP)

**Quickstart**: Uses embedded Dex (built-in IdP). First user created via `/setup` page.

**Production**: Any OIDC provider. Tested integrations:

| Self-Hosted | Managed |
|-------------|---------|
| Keycloak | Google Workspace |
| Zitadel | Microsoft Entra ID |
| Authentik | Okta |
| PocketID | Auth0 |

For Cloudron users: Cloudron's built-in OIDC provider works directly -- no Keycloak needed. The Cloudron app package registers Cloudron as a "Generic OIDC" identity provider automatically.

OIDC providers can be added via the dashboard (Settings > Identity Providers) or via API:

```bash
curl -X POST "https://netbird.example.com/api/identity-providers" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "oidc",
    "name": "My SSO Provider",
    "client_id": "your-client-id",
    "client_secret": "your-client-secret",
    "issuer": "https://sso.example.com"
  }'
```

Multiple IdPs can coexist (e.g., Cloudron SSO + Google + Keycloak). Local email/password auth is always available alongside external providers.

**JWT Group Sync**: NetBird can sync groups from your IdP via JWT claims. Enable in Settings > Groups > JWT group sync. Set the claim name (usually `groups`) and optionally restrict access to specific groups.

### Critical Gotchas

1. **UDP 3478 cannot be proxied** -- STUN requires direct UDP access
2. **SQLite = single instance only** -- no HA without PostgreSQL
3. **Encryption key is critical** -- `server.store.encryptionKey` encrypts tokens at rest; losing it means regenerating all keys
4. **Single account mode is default** -- all users join one network; disable with `--disable-single-account-mode` for multi-tenant
5. **The `/setup` page disappears** after first user creation -- save your admin credentials
6. **Hetzner firewalls are stateless** -- may need to open ephemeral UDP port range for STUN
7. **Oracle Cloud blocks UDP 3478** by default in both Security Rules and iptables
8. **Reverse proxy requires Traefik** -- NetBird's reverse proxy feature (exposing internal services publicly) requires Traefik with TLS passthrough. This is incompatible with Cloudron's nginx (see Cloudron section below). Does not affect core mesh VPN functionality.

## Standalone VPS Deployment (Full Features)

For full NetBird functionality including the reverse proxy feature, deploy on a dedicated VPS with Traefik. This is the recommended production deployment for aidevops.

### Recommended VPS Specs

| Peers | CPU | RAM | Disk | Monthly Cost (approx) |
|-------|-----|-----|------|-----------------------|
| 1-25 | 1 vCPU | 2 GB | 20 GB SSD | ~$4-6 (Hetzner CX22, Hostinger KVM1) |
| 25-100 | 2 vCPU | 4 GB | 40 GB SSD | ~$6-10 |
| 100-500 | 4 vCPU | 8 GB | 80 GB SSD | ~$15-20 |

A 1 vCPU / 2 GB VPS is sufficient for most self-hosted deployments. NetBird's management server is lightweight -- the main resource consumers are the database and concurrent gRPC connections.

### Prerequisites

- A VPS with Ubuntu 22.04+ (or any Linux with Docker)
- A public domain pointing to the VPS IP (e.g., `netbird.example.com`)
- (Optional) A proxy domain with wildcard DNS (e.g., `*.proxy.netbird.example.com`)
- Docker + docker-compose plugin installed
- Ports open: TCP 80, 443 + UDP 3478

### DNS Records

| Type | Name | Content | Notes |
|------|------|---------|-------|
| A | `netbird` | `YOUR.SERVER.IP` | Management server |
| CNAME | `proxy` | `netbird.example.com` | Reverse proxy (optional) |
| CNAME | `*.proxy` | `netbird.example.com` | Wildcard for proxy services (optional) |

### Installation

```bash
# SSH into your VPS
ssh root@your-vps-ip

# Install Docker if not present
curl -fsSL https://get.docker.com | sh

# Install jq
apt install -y jq

# Run the NetBird installer
export NETBIRD_DOMAIN=netbird.example.com
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh | bash
```

The installer prompts for:
1. **Reverse proxy**: Select `[0] Traefik` (default) for full functionality
2. **Proxy service**: Answer `y` to enable the reverse proxy feature
3. **Proxy domain**: Enter your proxy domain (e.g., `proxy.netbird.example.com`)

Generated files:

| File | Purpose |
|------|---------|
| `docker-compose.yml` | All services (netbird-server, dashboard, traefik, proxy) |
| `config.yaml` | Combined server config (management, signal, relay, STUN) |
| `dashboard.env` | Dashboard environment |
| `proxy.env` | Proxy environment (if enabled) |

### Post-Install

1. Open `https://netbird.example.com` and create your admin account on the `/setup` page
2. Create a Personal Access Token (Settings > Personal Access Tokens) -- save it securely
3. Create setup keys for device provisioning

### Health Check

```bash
# Check version and update availability via API
curl -s "https://netbird.example.com/api/instance/version" \
  -H "Authorization: Bearer <PAT>" | jq .

# Response includes:
# management_current_version, management_available_version, management_update_available
```

### Manual Upgrade

```bash
# 1. Backup first
docker compose exec netbird-server cat /var/lib/netbird/store.db > backup-$(date +%F).db 2>/dev/null || true
docker compose exec netbird-server pg_dump ... > backup-$(date +%F).sql 2>/dev/null || true

# 2. Pull latest images
docker compose pull netbird-server dashboard

# 3. Recreate containers
docker compose up -d --force-recreate netbird-server dashboard

# 4. Verify
docker compose ps
curl -s "https://netbird.example.com/api/instance/version" \
  -H "Authorization: Bearer <PAT>" | jq .management_current_version
```

### Automated Updates via aidevops

Create a cron job or aidevops scheduler task to check for updates and apply them automatically:

```bash
#!/bin/bash
# netbird-auto-update.sh -- run via cron or aidevops scheduler
# Place on the NetBird VPS at /opt/netbird/auto-update.sh
set -eu

NETBIRD_DIR="/opt/netbird"
NETBIRD_URL="https://netbird.example.com"
PAT_FILE="/opt/netbird/.pat"
LOG_FILE="/var/log/netbird-update.log"

log() { echo "$(date -Iseconds) $1" >> "$LOG_FILE"; }

# Check if PAT file exists
if [[ ! -f "$PAT_FILE" ]]; then
    log "ERROR: PAT file not found at $PAT_FILE"
    exit 1
fi
PAT=$(cat "$PAT_FILE")

# Check for updates via API
RESPONSE=$(curl -sf "${NETBIRD_URL}/api/instance/version" \
    -H "Authorization: Bearer ${PAT}" \
    -H "Accept: application/json" 2>/dev/null || echo '{}')

UPDATE_AVAILABLE=$(echo "$RESPONSE" | jq -r '.management_update_available // false')
CURRENT=$(echo "$RESPONSE" | jq -r '.management_current_version // "unknown"')
AVAILABLE=$(echo "$RESPONSE" | jq -r '.management_available_version // "unknown"')

if [[ "$UPDATE_AVAILABLE" != "true" ]]; then
    log "OK: NetBird ${CURRENT} is up to date"
    exit 0
fi

log "UPDATE: ${CURRENT} -> ${AVAILABLE}"

# Pull and recreate
cd "$NETBIRD_DIR"
docker compose pull netbird-server dashboard >> "$LOG_FILE" 2>&1
docker compose up -d --force-recreate netbird-server dashboard >> "$LOG_FILE" 2>&1

# Verify
sleep 10
NEW_VERSION=$(curl -sf "${NETBIRD_URL}/api/instance/version" \
    -H "Authorization: Bearer ${PAT}" | jq -r '.management_current_version // "unknown"')

if [[ "$NEW_VERSION" == "$AVAILABLE" ]]; then
    log "SUCCESS: Updated to ${NEW_VERSION}"
else
    log "WARNING: Expected ${AVAILABLE} but got ${NEW_VERSION}"
fi
```

Install the cron job:

```bash
# Save PAT securely
echo "YOUR_PAT_HERE" > /opt/netbird/.pat
chmod 600 /opt/netbird/.pat

# Make script executable
chmod +x /opt/netbird/auto-update.sh

# Run daily at 3am
echo "0 3 * * * root /opt/netbird/auto-update.sh" > /etc/cron.d/netbird-update
```

Or via aidevops remote dispatch (if the VPS is on the mesh):

```bash
# From any mesh peer with aidevops
ssh netbird-vps.netbird.cloud "/opt/netbird/auto-update.sh"
```

### Monitoring via aidevops

Add a health check to the aidevops scheduler:

```bash
# Check NetBird health from any mesh peer
curl -sf "https://netbird.example.com/api/instance/version" \
  -H "Authorization: Bearer <PAT>" | jq '{
    version: .management_current_version,
    update_available: .management_update_available,
    latest: .management_available_version
  }'

# Check peer count
curl -sf "https://netbird.example.com/api/peers" \
  -H "Authorization: Token <PAT>" | jq 'length'

# Check connected vs total peers
curl -sf "https://netbird.example.com/api/peers" \
  -H "Authorization: Token <PAT>" | jq '{
    total: length,
    connected: [.[] | select(.connected == true)] | length
  }'
```

## Coolify Deployment (Recommended)

Coolify uses **Traefik natively** as its reverse proxy, which means it supports the full NetBird feature set -- including the reverse proxy feature that requires TLS passthrough. Combined with Coolify's management UI, Docker Compose build pack, persistent storage, and environment variable management, this is the **best deployment option** for aidevops users who already run Coolify.

### Why Coolify over standalone VPS

| Aspect | Standalone VPS | Coolify |
|--------|---------------|---------|
| Reverse proxy | Full (Traefik) | Full (Traefik, native) |
| Management UI | SSH + CLI only | Coolify dashboard |
| TLS certificates | Traefik Let's Encrypt | Coolify-managed Let's Encrypt |
| Updates | Manual or cron script | Coolify redeploy |
| Monitoring | Custom scripts | Coolify built-in + custom |
| Backups | Manual | Coolify volume backups |
| Multi-service | Docker Compose only | Full PaaS with other apps |

### Prerequisites

- A Coolify instance (v4.x) with a connected server
- A public domain pointing to the Coolify server (e.g., `netbird.example.com`)
- (Optional) Wildcard DNS for the proxy feature (e.g., `*.proxy.netbird.example.com`)
- UDP port 3478 open on the server firewall (STUN -- cannot be proxied)

### DNS Records

| Type | Name | Content | Notes |
|------|------|---------|-------|
| A | `netbird` | `COOLIFY.SERVER.IP` | Management server |
| CNAME | `proxy` | `netbird.example.com` | Reverse proxy (optional) |
| CNAME | `*.proxy` | `netbird.example.com` | Wildcard for proxy services (optional) |

### Step 1: Generate NetBird config on a temporary machine

NetBird's `getting-started.sh` script generates the Docker Compose and config files. Run it once on any machine to generate the files, then deploy them via Coolify.

```bash
# On any Linux machine with Docker (can be temporary)
export NETBIRD_DOMAIN=netbird.example.com
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh | bash
```

When prompted:
1. **Reverse proxy**: Select `[1] Existing Traefik` (Coolify already provides Traefik)
2. **Proxy service**: Answer `y` if you want the reverse proxy feature
3. **Proxy domain**: Enter your proxy domain (e.g., `proxy.netbird.example.com`)

This generates:
- `docker-compose.yml` -- all NetBird services (without Traefik, since Coolify provides it)
- `config.yaml` -- combined server config
- `dashboard.env` -- dashboard environment variables
- `proxy.env` -- proxy environment variables (if enabled)

### Step 2: Adapt the Docker Compose for Coolify

The generated `docker-compose.yml` needs minor adjustments for Coolify:

1. **Remove the Traefik service** (if present) -- Coolify provides its own Traefik
2. **Add Traefik labels** to the dashboard service for domain routing
3. **Expose UDP 3478** via port mapping for STUN
4. **Use bind mounts** for persistent config

Example adapted compose (adjust based on your generated file):

```yaml
services:
  netbird-server:
    image: netbirdio/netbird:latest
    restart: unless-stopped
    volumes:
      - type: bind
        source: ./config.yaml
        target: /etc/netbird/config.yaml
        content: |
          # Paste your generated config.yaml content here
          # Coolify will create this file automatically
      - netbird-data:/var/lib/netbird
    ports:
      # STUN -- must be exposed directly, cannot be proxied
      - "3478:3478/udp"

  dashboard:
    image: netbirdio/dashboard:latest
    restart: unless-stopped
    env_file:
      - dashboard.env
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.netbird-dashboard.rule=Host(`netbird.example.com`)"
      - "traefik.http.routers.netbird-dashboard.tls=true"
      - "traefik.http.routers.netbird-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.services.netbird-dashboard.loadbalancer.server.port=80"

  # Only if proxy feature is enabled
  netbird-proxy:
    image: netbirdio/netbird-proxy:latest
    restart: unless-stopped
    env_file:
      - proxy.env
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.netbird-proxy.rule=HostRegexp(`{subdomain:.+}.proxy.netbird.example.com`)"
      - "traefik.http.routers.netbird-proxy.tls=true"
      - "traefik.http.routers.netbird-proxy.tls.certresolver=letsencrypt"
      - "traefik.http.services.netbird-proxy.loadbalancer.server.port=443"
      - "traefik.tcp.routers.netbird-proxy-tls.rule=HostSNI(`*.proxy.netbird.example.com`)"
      - "traefik.tcp.routers.netbird-proxy-tls.tls.passthrough=true"

volumes:
  netbird-data:
```

### Step 3: Deploy via Coolify

1. In Coolify dashboard, create a new **Application** (not Service)
2. Select **Docker Compose** as the build pack
3. Choose deployment method:
   - **Git repository**: Push the adapted compose + config files to a repo, connect it
   - **Raw Docker Compose**: Paste the compose content directly in the Coolify UI
4. Set the domain for the dashboard service to `netbird.example.com`
5. Configure environment variables in Coolify's UI (from `dashboard.env` and `proxy.env`)
6. Deploy

### Step 4: Post-deployment

1. Open `https://netbird.example.com` and create your admin account on the `/setup` page
2. Create a Personal Access Token (Settings > Personal Access Tokens)
3. Store the PAT securely: `aidevops secret set NETBIRD_PAT`
4. Create setup keys for device provisioning

### Coolify-specific considerations

**UDP port 3478**: Coolify's Docker Compose build pack supports port mapping via the `ports` directive. The STUN port is mapped directly to the host, bypassing Traefik (UDP cannot be proxied through HTTP reverse proxies).

**Persistent storage**: Use Coolify's volume management or bind mounts. The `netbird-data` volume holds the database (SQLite) and encryption keys. For production, consider adding a PostgreSQL database via Coolify's database feature and updating `config.yaml` accordingly.

**Updates**: Redeploy from Coolify's dashboard to pull latest images. Coolify can be configured for auto-deploy on image tag changes.

**TLS passthrough for reverse proxy**: Coolify's Traefik supports TCP routers with TLS passthrough via labels. This is what enables the NetBird reverse proxy feature -- the key capability that Cloudron cannot provide.

**Wildcard certificates**: If using the proxy feature, configure Coolify's Traefik for wildcard certificates via DNS challenge. See Coolify docs: Knowledge Base > Proxy > Traefik > Wildcard SSL Certificates.

**Health checks**: Add a health check to the netbird-server service:

```yaml
services:
  netbird-server:
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:80/api/accounts"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
```

### Dokploy (Alternative to Coolify)

[Dokploy](https://dokploy.com) is another open-source, Traefik-based PaaS with Docker Compose support. The same deployment approach used for Coolify works for Dokploy with minor differences:

- **Traefik labels**: Same syntax -- Dokploy uses Traefik natively
- **Docker Compose**: Supported as a first-class build pack
- **Port mapping**: `ports` directive works the same way for UDP 3478
- **Environment variables**: Set via UI or `.env` file (use `env_file` in compose)
- **Persistent storage**: Named volumes or bind mounts via `../files/` directory
- **Wildcard certs**: Supported via Traefik DNS challenge

Key differences from Coolify:

| Aspect | Coolify | Dokploy |
|--------|---------|---------|
| Volume backups | Yes | Yes (named volumes only) |
| Bind mount persistence | Standard Docker | Use `../files/` prefix (cleaned on deploy otherwise) |
| Git integrations | GitHub, GitLab, Bitbucket | GitHub, GitLab, Bitbucket, Gitea |
| Swarm mode | No | Yes (Docker Stack) |
| License | Apache-2.0 | Apache-2.0 |

To deploy on Dokploy: follow the same Steps 1-4 as Coolify above, substituting "Coolify dashboard" with "Dokploy dashboard". The Docker Compose file and Traefik labels are identical.

See: https://dokploy.com/docs/core/docker-compose

### Feature comparison across deployment options

| Feature | Cloudron | Standalone VPS | Coolify / Dokploy |
|---------|----------|---------------|-------------------|
| Mesh VPN (P2P tunnels) | Yes | Yes | Yes |
| NAT traversal (STUN/TURN) | Yes | Yes | Yes |
| Dashboard + API | Yes | Yes | Yes |
| SSO (OIDC) | Yes (Cloudron SSO) | Yes (any IdP) | Yes (any IdP) |
| PostgreSQL | Yes (addon) | Yes (manual) | Yes (PaaS DB) |
| Reverse proxy feature | **No** | Yes | **Yes** |
| Management UI for infra | Cloudron | None (SSH) | PaaS dashboard |
| Auto-TLS | Cloudron | Traefik | PaaS/Traefik |
| Wildcard certs | Limited | Yes | Yes |
| Cost overhead | Cloudron license | None | None (open source) |

## Client Installation

### macOS

```bash
# Via Homebrew
brew install netbirdio/tap/netbird

# Start and connect
sudo netbird up

# Or with a setup key (headless/automated)
sudo netbird up --setup-key <SETUP_KEY>
```

### Linux (Ubuntu/Debian)

```bash
# One-line install
curl -fsSL https://pkgs.netbird.io/install.sh | sh

# Enable and start
sudo systemctl enable --now netbird

# Connect
sudo netbird up

# Or with setup key for automated provisioning
sudo netbird up --setup-key <SETUP_KEY>
```

### Linux (Docker)

```bash
docker run -d \
  --name netbird \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  -v netbird-client:/etc/netbird \
  netbirdio/netbird:latest \
  up --setup-key <SETUP_KEY> \
  --management-url https://netbird.example.com
```

### Raspberry Pi / ARM

```bash
# Same as Linux -- the install script detects architecture
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo netbird up --setup-key <SETUP_KEY>
```

### Proxmox Host (direct install)

```bash
# Install on the Proxmox host itself (not in a VM)
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo netbird up --setup-key <SETUP_KEY>

# Optionally advertise the Proxmox subnet as a network route
# (allows mesh peers to reach VMs on the Proxmox bridge)
```

### Proxmox LXC Container

Running NetBird in an unprivileged LXC requires `/dev/tun` passthrough. On the Proxmox host shell:

```bash
# Edit the LXC config (replace 100 with your CT ID)
nano /etc/pve/lxc/100.conf

# Add these lines at the bottom:
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net dev/net none bind,create=dir
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Then restart the container and install normally:

```bash
# Inside the LXC
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo netbird up --setup-key <SETUP_KEY>
```

Recommended LXC specs for NetBird client only: 1 core, 1 GB RAM, 8 GB disk. Enable start-on-boot in LXC options.

See: https://docs.netbird.io/get-started/install/proxmox-ve

### Synology NAS

Requires SSH access and admin privileges. The TUN device may not persist across reboots.

```bash
# SSH into Synology
ssh user@synology-ip

# Install
curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh

# Connect
sudo netbird up --setup-key <SETUP_KEY>
```

**Reboot script** (required on some Synology models): Create a triggered task in DSM (Control Panel > Task Scheduler > Triggered Task > Boot-up) running as root:

```bash
#!/bin/sh
if [ ! -c /dev/net/tun ]; then
  [ ! -d /dev/net ] && mkdir -m 755 /dev/net
  mknod /dev/net/tun c 10 200
  chmod 0755 /dev/net/tun
fi
if ! lsmod | grep -q "^tun\s"; then
  insmod /lib/modules/tun.ko
fi
```

See: https://docs.netbird.io/get-started/install/synology

### pfSense

NetBird has an official pfSense package (under review for the package manager). Key gotcha: pfSense's automatic outbound NAT randomizes source ports, which breaks NAT traversal. You must configure a Static Port mapping rule.

```bash
# SSH into pfSense, then download and install
fetch https://github.com/netbirdio/pfsense-netbird/releases/download/v0.1.2/netbird-0.55.1.pkg
fetch https://github.com/netbirdio/pfsense-netbird/releases/download/v0.1.2/pfSense-pkg-NetBird-0.1.0.pkg
pkg add -f netbird-0.55.1.pkg
pkg add -f pfSense-pkg-NetBird-0.1.0.pkg
```

After install: configure via VPN > NetBird in the pfSense UI. Assign the `wt0` interface and create a "pass all" firewall rule on it (NetBird ACLs handle access control).

For direct connections (not relayed): Firewall > NAT > Outbound > Hybrid mode, add a Static Port rule for the NetBird host's UDP traffic on WAN.

See: https://docs.netbird.io/get-started/install/pfsense

### OPNSense

```bash
# SSH into OPNSense
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --setup-key <SETUP_KEY>
```

See: https://docs.netbird.io/get-started/install/opnsense

### TrueNAS

```bash
# Via SSH or TrueNAS shell
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --setup-key <SETUP_KEY>
```

See: https://docs.netbird.io/get-started/install/truenas

### All Supported Client Platforms

| Platform | Install Method | Gotchas |
|----------|---------------|---------|
| macOS | Homebrew | None |
| Linux (any) | Install script | None |
| Windows | MSI installer | Run as admin |
| Docker | Container | `NET_ADMIN` + `SYS_ADMIN` caps required |
| Raspberry Pi / ARM | Install script (auto-detects arch) | None |
| Proxmox host | Install script | None |
| Proxmox LXC | Install script | Needs `/dev/tun` passthrough in LXC config |
| Synology | Install script via SSH | May need reboot script for TUN device |
| pfSense | Official `.pkg` package | Static Port NAT rule needed for direct connections |
| OPNSense | Install script | None |
| TrueNAS | Install script | None |
| iOS / Android | App Store / Play Store | Mobile only, no setup key support |
| tvOS / Android TV | App Store / Play Store | Limited to TV interface |

Full install docs: https://docs.netbird.io/get-started/install

### Verify Connection

```bash
# Show all peers
netbird status

# Show detailed peer info
netbird status --detail

# Check your mesh IP
netbird status | grep "NetBird IP"
```

## aidevops Integration

### 1. AI Worker Mesh Provisioning

Create setup keys for automated worker provisioning:

```bash
# Via API: Create a reusable setup key for AI workers
curl -s -X POST "https://netbird.example.com/api/setup-keys" \
  -H "Authorization: Token <API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "aidevops-workers",
    "type": "reusable",
    "expires_in": 86400,
    "auto_groups": ["ai-workers"],
    "usage_limit": 50
  }'
```

Then in worker provisioning scripts:

```bash
# Automated worker setup (no interactive auth needed)
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo netbird up \
  --setup-key "$NETBIRD_SETUP_KEY" \
  --management-url "https://netbird.example.com"
```

### 2. Access Control Groups

Recommended group structure for aidevops:

| Group | Members | Purpose |
|-------|---------|---------|
| `humans` | Developer machines | Full access to admin UIs |
| `ai-workers` | AI agent machines | Access to build/deploy services only |
| `build-servers` | CI/CD machines | Access to repos, registries, deploy targets |
| `production` | Production servers | Restricted -- only deploy pipeline access |
| `monitoring` | All servers | Metrics and logging access |

### 3. Private DNS for Service Discovery

Configure DNS names in the NetBird dashboard so workers can reach services by name:

```text
build01.netbird.cloud  -> 100.64.x.x  (build server)
gpu-node.netbird.cloud -> 100.64.x.x  (GPU compute)
registry.netbird.cloud -> 100.64.x.x  (container registry)
coolify.netbird.cloud  -> 100.64.x.x  (deployment platform)
cloudron.netbird.cloud -> 100.64.x.x  (app platform)
```

### 4. Secure Access to Self-Hosted Services

Access Cloudron, Coolify, Proxmox, and other dashboards without exposing them publicly:

```bash
# All these are now accessible only via the mesh:
# https://cloudron.netbird.cloud
# https://coolify.netbird.cloud:8000
# https://proxmox.netbird.cloud:8006
```

### 5. Network Routes (Site-to-Site)

Advertise local subnets through a mesh peer:

```bash
# On a Proxmox host: advertise the VM bridge subnet
# Configure via dashboard: Network Routes -> Add Route
# Peer: proxmox-host, Network: 10.10.10.0/24
# Now all mesh peers can reach Proxmox VMs directly
```

### 6. API Automation

NetBird has a full REST API for programmatic management:

```bash
# List all peers
curl -s "https://netbird.example.com/api/peers" \
  -H "Authorization: Token <API_TOKEN>" | jq '.[] | {name, ip, connected}'

# Create a group
curl -s -X POST "https://netbird.example.com/api/groups" \
  -H "Authorization: Token <API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"name": "ai-workers"}'

# Create an access policy
curl -s -X POST "https://netbird.example.com/api/policies" \
  -H "Authorization: Token <API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ai-workers-to-build",
    "enabled": true,
    "rules": [{
      "name": "allow-build-access",
      "enabled": true,
      "sources": ["<ai-workers-group-id>"],
      "destinations": ["<build-servers-group-id>"],
      "bidirectional": true,
      "protocol": "all",
      "action": "accept"
    }]
  }'
```

### 7. Terraform Provider

For infrastructure-as-code management:

```hcl
terraform {
  required_providers {
    netbird = {
      source = "netbirdio/netbird"
    }
  }
}

provider "netbird" {
  server_url = "https://netbird.example.com"
  token      = var.netbird_api_token
}

resource "netbird_setup_key" "workers" {
  name        = "aidevops-workers"
  type        = "reusable"
  auto_groups = [netbird_group.ai_workers.id]
}

resource "netbird_group" "ai_workers" {
  name = "ai-workers"
}
```

## Cloudron Deployment

A Cloudron app package exists at https://github.com/marcusquinn/cloudron-netbird-app.

### What works on Cloudron

| Feature | Status | Notes |
|---------|--------|-------|
| Management server | Works | Combined `netbird-server` binary |
| Dashboard | Works | Static files served via nginx |
| Signal server (gRPC) | Works | nginx `grpc_pass` routing |
| Relay (WebSocket) | Works | nginx proxy with upgrade headers |
| STUN (UDP 3478) | Works | Exposed via `tcpPorts` manifest option |
| PostgreSQL | Works | Cloudron addon, auto-configured |
| Cloudron SSO (OIDC) | Works | Cloudron's built-in OIDC provider, no Keycloak needed |
| Cloudron TURN relay | Works | Cloudron addon, auto-configured for NAT traversal |
| **Reverse proxy** | **Not supported** | Requires Traefik with TLS passthrough; Cloudron uses nginx |

### Cloudron addons used

| Addon | Purpose |
|-------|---------|
| `postgresql` | Database (replaces default SQLite) |
| `localstorage` | Persistent data at `/app/data/` |
| `oidc` | Cloudron SSO -- provides `CLOUDRON_OIDC_ISSUER`, `CLIENT_ID`, `CLIENT_SECRET` |
| `turn` | NAT traversal relay -- provides `CLOUDRON_TURN_SERVER`, `TURN_PORT`, `TURN_SECRET` |

### OIDC integration

Cloudron's OIDC addon provides credentials that are registered as a "Generic OIDC" identity provider in NetBird via the REST API on startup. This requires a Personal Access Token (PAT) stored at `/app/data/config/.admin_pat`. Without it, manual setup instructions are printed to the app logs.

The OIDC registration is stored in PostgreSQL (not config files), so it persists across restarts. The startup script checks for existing registration to avoid duplicates.

### Reverse proxy limitation

NetBird's reverse proxy feature (exposing internal services to the public internet with automatic TLS) requires Traefik with TLS passthrough. Cloudron's nginx terminates TLS before traffic reaches the app container, making TLS passthrough impossible. This is a fundamental architectural constraint of Cloudron, not a packaging issue.

A feature request for TLS passthrough support has been submitted to the Cloudron forum. If added, it would unblock the reverse proxy feature.

**This does not affect core mesh VPN functionality.** All P2P tunnels, NAT traversal, access control, DNS, network routes, and the management dashboard work normally.

### Packaging reference

See `tools/deployment/cloudron-app-packaging.md` for the general Cloudron packaging guide.

## Comparison with Tailscale

| Feature | NetBird | Tailscale |
|---------|---------|-----------|
| Control plane | Self-hosted (AGPL) | Proprietary (Headscale as workaround) |
| Client license | BSD-3 | BSD-3 |
| REST API | Full, self-hosted | Full, cloud-hosted |
| Terraform | Official provider | Official provider |
| SSO/MFA | Any OIDC provider (multiple simultaneous) | Google/Microsoft/GitHub |
| ACLs | Group-based, dashboard UI | JSON policy file |
| DNS | Built-in private DNS | MagicDNS |
| NAT traversal | ICE + TURN relay | DERP relay |
| Reverse proxy | Yes (beta, self-hosted only, requires Traefik) | Tailscale Funnel |
| Quantum resistance | Rosenpass | Not available |
| Setup keys | Yes (bulk provisioning) | Auth keys |
| Multi-user | Yes, with IdP | Yes, with identity provider |
| JWT group sync | Yes (any OIDC claim) | Limited |
| Vendor lock-in | None | High (proprietary control plane) |

**When to use Tailscale instead**: If you want zero setup effort and don't mind vendor dependency. Tailscale's free tier (100 devices, 3 users) is generous for personal use.

**When to use NetBird**: When you need full control, self-hosting, API automation, team scaling, or can't accept proprietary control plane dependency.

## Reverse Proxy (Exposing Internal Services)

NetBird v0.65+ includes a reverse proxy feature (beta, self-hosted only) that exposes internal services on mesh peers to the public internet with automatic TLS and optional SSO/password/PIN authentication.

### How it works

1. Create a "service" in the dashboard mapping a public domain to an internal peer + port
2. NetBird provisions a TLS certificate and creates a WireGuard tunnel to the target peer
3. Incoming HTTPS requests are terminated at the NetBird proxy, then forwarded through the mesh
4. Optional authentication: SSO (via configured IdP), password, or PIN

### Requirements

- A separate `netbirdio/netbird-proxy` container connected to the management server
- **Traefik** as the reverse proxy (required for TLS passthrough -- nginx is not supported)
- DNS: A record for the NetBird host + CNAME records for `proxy` and `*.proxy`
- The `getting-started.sh` installer (v0.65+) includes the proxy container when Traefik is selected

### Key features

- **Path-based routing**: Multiple targets per service (e.g., `/api` -> backend, `/` -> frontend)
- **Custom domains**: CNAME to your proxy cluster address
- **High availability**: Multiple proxy instances with the same `NB_PROXY_DOMAIN` form a cluster
- **TLS modes**: ACME (Let's Encrypt, automatic) or static certificates (wildcard/corporate CA)
- **Hot reload**: Static certificates are watched for changes, no restart needed

### Limitations

- **Requires Traefik** -- not compatible with nginx-based reverse proxies (including Cloudron)
- **No pre-shared keys or Rosenpass** -- incompatible with the reverse proxy feature
- **Beta** -- cloud support coming soon, currently self-hosted only
- **Not a replacement for Cloudflare Tunnel** -- designed for exposing services within the mesh, not as a general-purpose tunnel

### When to use it

Use the reverse proxy when you want to expose an internal service (e.g., a dashboard on a Proxmox VM) to the internet without opening ports or configuring firewalls on the target machine. The service only needs to be reachable within the NetBird mesh.

For Cloudron users: deploy NetBird standalone (outside Cloudron) with Traefik if you need this feature.

## Troubleshooting

```bash
# Check client status and peer connections
netbird status --detail

# Check if daemon is running
systemctl status netbird

# View client logs
journalctl -u netbird -f

# View management server logs (Docker)
docker compose logs -f netbird-server

# Re-authenticate
netbird down && netbird up

# Force relay (debug connectivity)
netbird up --disable-auto-connect

# Check NAT traversal
netbird status --detail  # Look for "direct" vs "relayed" connections

# Reset client state
netbird down
rm -rf /etc/netbird/
netbird up --setup-key <KEY>
```

### Common Issues

**Peers show "disconnected"**:
- Check UDP 3478 is open on the management server
- Check firewall allows WireGuard UDP traffic between peers
- Try `netbird status --detail` to see if connections are direct or relayed

**Management server unreachable**:
- Verify DNS resolves to the correct IP
- Check TLS certificate is valid (`curl -v https://netbird.example.com`)
- Check Docker containers are running (`docker compose ps`)

**Setup key rejected**:
- Key may be expired or usage limit reached
- Check key status in dashboard under Setup Keys

## Resources

- **Docs**: https://docs.netbird.io
- **Self-Hosting Guide**: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- **Identity Providers**: https://docs.netbird.io/selfhosted/identity-providers
- **Generic OIDC Setup**: https://docs.netbird.io/selfhosted/identity-providers/generic-oidc
- **Reverse Proxy**: https://docs.netbird.io/manage/reverse-proxy
- **API Reference**: https://docs.netbird.io/api
- **Terraform Provider**: https://registry.terraform.io/providers/netbirdio/netbird/latest
- **GitHub**: https://github.com/netbirdio/netbird
- **Cloudron Package**: https://github.com/marcusquinn/cloudron-netbird-app
- **Slack**: https://docs.netbird.io/slack-url
- **Forum**: https://forum.netbird.io
