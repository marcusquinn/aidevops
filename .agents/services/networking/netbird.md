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
- **GitHub**: https://github.com/netbirdio/netbird (22.9k stars)

**Key Concepts**:

- **Management Server**: Holds network state, distributes peer configs, manages ACLs
- **Signal Server**: Brokers WebRTC ICE candidates for P2P connection setup
- **Relay Server**: Fallback when direct P2P fails (strict NAT, carrier-grade NAT)
- **Setup Key**: Pre-authenticated token for bulk device provisioning (ideal for AI workers)
- **Peer Group**: Logical grouping of devices for ACL rules
- **Network Route**: Advertise subnets reachable through a peer (site-to-site)
- **Private DNS**: Resolve peer names within the mesh (e.g., `build01.netbird.cloud`)

<!-- AI-CONTEXT-END -->

## Architecture

```text
Management Server (network state, ACLs, peer registry)
Signal Server (WebRTC ICE negotiation)
Relay Server (TURN fallback for strict NAT)
        │
        ├── Mac Client ←→ Linux Client ←→ VPS Client
        └── Proxmox Client ←→ Pi Client ←→ Docker Client
                    (WireGuard P2P mesh — all traffic peer-to-peer)
```

All traffic is peer-to-peer WireGuard. The management server only coordinates — no data flows through it.

## Self-Hosting the Control Plane

### Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 2 GB | 4 GB |
| Ports | TCP 80, 443 + UDP 3478 | Same |
| OS | Any Linux with Docker | Ubuntu 22.04+ |

### Quickstart (Docker Compose)

```bash
export NETBIRD_DOMAIN=netbird.example.com
NETBIRD_VERSION="v0.35.0"  # pin to a verified release — check https://github.com/netbirdio/netbird/releases
curl -fsSL "https://github.com/netbirdio/netbird/releases/download/${NETBIRD_VERSION}/getting-started.sh" \
  -o /tmp/netbird-setup.sh
# Verify the checksum before executing (see release page for SHA256)
bash /tmp/netbird-setup.sh
```

**Always pin to a specific release tag and verify the script checksum.** The `latest` URL is unversioned and unsuitable for reproducible provisioning.

Deploys: `netbird-server` (combined management + signal + relay + STUN), `dashboard` (web UI), `traefik` (reverse proxy + Let's Encrypt TLS).

### Port Requirements

| Port | Protocol | Purpose | Proxyable? |
|------|----------|---------|------------|
| 80 | TCP | HTTP / ACME validation | Yes |
| 443 | TCP | HTTPS (dashboard, API, gRPC, relay WebSocket) | Yes |
| 3478 | UDP | STUN (NAT traversal) | **No — must be exposed directly** |

### Database Options

| Engine | Use Case |
|--------|----------|
| SQLite (default) | Small deployments (<50 peers), zero config, no HA |
| PostgreSQL | Production — concurrent access, HA-capable |

### Identity Provider (IdP)

**Quickstart**: Uses embedded Dex (built-in IdP). First user created via `/setup` page.

**Production**: Any OIDC provider. Tested: Keycloak, Zitadel, Authentik, PocketID (self-hosted); Google Workspace, Microsoft Entra ID, Okta, Auth0 (managed).

For Cloudron users: Cloudron's built-in OIDC provider works directly — no Keycloak needed.

```bash
curl -X POST "https://netbird.example.com/api/identity-providers" \
  -H "Authorization: Token ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"type":"oidc","name":"My SSO Provider","client_id":"...","client_secret":"...","issuer":"https://sso.example.com"}'
```

**JWT Group Sync**: Enable in Settings > Groups > JWT group sync. Set the claim name (usually `groups`).

### Critical Gotchas

1. **UDP 3478 cannot be proxied** — STUN requires direct UDP access
2. **SQLite = single instance only** — no HA without PostgreSQL
3. **Encryption key is critical** — `server.store.encryptionKey` encrypts tokens at rest; losing it means regenerating all keys
4. **Single account mode is default** — disable with `--disable-single-account-mode` for multi-tenant
5. **The `/setup` page disappears** after first user creation — save your admin credentials
6. **Hetzner Dedicated (Robot) firewall is stateless** — may need to open ephemeral UDP port range for STUN; Hetzner Cloud firewalls are stateful
7. **Oracle Cloud blocks UDP 3478** by default in both Security Rules and iptables
8. **Reverse proxy requires Traefik** — incompatible with Cloudron's nginx (see Cloudron section)

## Deployment Options

### Standalone VPS (Full Features)

Recommended for full NetBird functionality including the reverse proxy feature.

**VPS sizing**: 1-25 peers → 1 vCPU / 2 GB / ~$4-6/mo (Hetzner CX22); 25-100 peers → 2 vCPU / 4 GB / ~$6-10/mo.

**DNS records**:

| Type | Name | Content |
|------|------|---------|
| A | `netbird` | `YOUR.SERVER.IP` |
| CNAME | `proxy` | `netbird.example.com` (optional) |
| CNAME | `*.proxy` | `netbird.example.com` (optional, wildcard for proxy services) |

**Installation**: Run the quickstart script above. When prompted: select `[0] Traefik` as reverse proxy; answer `y` to enable proxy service; enter proxy domain.

**Post-install**: Open `https://netbird.example.com`, create admin account on `/setup` page, create Personal Access Token (Settings > Personal Access Tokens), create setup keys for device provisioning.

**Health check**:

```bash
curl -s "https://netbird.example.com/api/instance/version" \
  -H "Authorization: Token <PAT>" | jq .
# Returns: management_current_version, management_available_version, management_update_available
```

**Manual upgrade**:

```bash
docker compose exec netbird-server cat /var/lib/netbird/store.db > backup-$(date +%F).db 2>/dev/null || true
docker compose pull netbird-server dashboard
docker compose up -d --force-recreate netbird-server dashboard
```

**Automated updates** (cron or aidevops scheduler):

```bash
#!/bin/bash
# /opt/netbird/auto-update.sh
set -eu
PAT=$(cat /opt/netbird/.pat)
RESPONSE=$(curl -sf "https://netbird.example.com/api/instance/version" \
  -H "Authorization: Token ${PAT}" -H "Accept: application/json" 2>/dev/null || echo '{}')
UPDATE_AVAILABLE=$(echo "$RESPONSE" | jq -r '.management_update_available // false')
[[ "$UPDATE_AVAILABLE" != "true" ]] && exit 0
AVAILABLE=$(echo "$RESPONSE" | jq -r '.management_available_version // "unknown"')
cd /opt/netbird
docker compose pull netbird-server dashboard
docker compose up -d --force-recreate netbird-server dashboard
echo "Updated to ${AVAILABLE}"
```

```bash
echo "YOUR_PAT_HERE" > /opt/netbird/.pat && chmod 600 /opt/netbird/.pat
chmod +x /opt/netbird/auto-update.sh
echo "0 3 * * * root /opt/netbird/auto-update.sh" > /etc/cron.d/netbird-update
```

### Coolify Deployment (Recommended for Coolify users)

Coolify uses Traefik natively, supporting the full NetBird feature set including the reverse proxy feature.

| Aspect | Standalone VPS | Coolify |
|--------|---------------|---------|
| Reverse proxy | Full (Traefik) | Full (Traefik, native) |
| Management UI | SSH + CLI only | Coolify dashboard |
| Updates | Manual or cron | Coolify redeploy |
| Backups | Manual | Coolify volume backups |

**Step 1**: Generate NetBird config on any temporary machine (same quickstart script, select `[1] Existing Traefik`).

**Step 2**: Adapt the Docker Compose for Coolify — remove the Traefik service, add Traefik labels to dashboard service, expose UDP 3478 via port mapping:

```yaml
services:
  netbird-server:
    image: netbirdio/netbird:v0.35.0
    restart: unless-stopped
    volumes:
      - netbird-data:/var/lib/netbird
    ports:
      - "3478:3478/udp"  # STUN — must be exposed directly

  dashboard:
    image: netbirdio/dashboard:v2.9.0
    restart: unless-stopped
    env_file: [dashboard.env]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.netbird-dashboard.rule=Host(`netbird.example.com`)"
      - "traefik.http.routers.netbird-dashboard.tls=true"
      - "traefik.http.routers.netbird-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.services.netbird-dashboard.loadbalancer.server.port=80"

  # Only if proxy feature is enabled
  netbird-proxy:
    image: netbirdio/netbird-proxy:v0.35.0
    restart: unless-stopped
    env_file: [proxy.env]
    labels:
      - "traefik.enable=true"
      - "traefik.tcp.routers.netbird-proxy-tls.rule=HostSNI(`*.proxy.netbird.example.com`)"
      - "traefik.tcp.routers.netbird-proxy-tls.tls.passthrough=true"

volumes:
  netbird-data:
```

**Step 3**: In Coolify, create a new Application > Docker Compose build pack, set domain to `netbird.example.com`, configure environment variables from `dashboard.env`, deploy.

**Dokploy** (alternative to Coolify): Same approach — Traefik-based PaaS with Docker Compose support. Identical Traefik labels. Use `../files/` prefix for bind mount persistence.

### Feature Comparison

| Feature | Cloudron | Standalone VPS | Coolify / Dokploy |
|---------|----------|---------------|-------------------|
| Mesh VPN, NAT traversal, Dashboard + API | Yes | Yes | Yes |
| SSO (OIDC) | Yes (Cloudron SSO) | Yes (any IdP) | Yes (any IdP) |
| PostgreSQL | Yes (add-on) | Yes (manual) | Yes (PaaS DB) |
| **Reverse proxy feature** | **No** | Yes | **Yes** |
| Management UI for infra | Cloudron | None (SSH) | PaaS dashboard |

## Client Installation

```bash
# macOS (Homebrew)
brew install netbirdio/tap/netbird && sudo netbird up

# Linux (Ubuntu/Debian)
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo systemctl enable --now netbird && sudo netbird up

# Linux (Docker)
docker run -d --name netbird --cap-add NET_ADMIN --cap-add SYS_ADMIN \
  -v netbird-client:/etc/netbird netbirdio/netbird:v0.35.0 \
  up --setup-key <SETUP_KEY> --management-url https://netbird.example.com

# Raspberry Pi / ARM — same as Linux (install script detects architecture)
curl -fsSL https://pkgs.netbird.io/install.sh | sh && sudo netbird up --setup-key <SETUP_KEY>

# Proxmox host
curl -fsSL https://pkgs.netbird.io/install.sh | sh && sudo netbird up --setup-key <SETUP_KEY>
```

### Proxmox LXC Container

Requires `/dev/tun` passthrough. On the Proxmox host shell:

```bash
# Edit LXC config (replace 100 with your CT ID)
nano /etc/pve/lxc/100.conf
# Add:
# lxc.cgroup2.devices.allow: c 10:200 rwm
# lxc.mount.entry: /dev/net dev/net none bind,create=dir
# lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Then restart the container and install normally.

### Synology NAS

```bash
ssh user@synology-ip
curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh
sudo netbird up --setup-key <SETUP_KEY>
```

**Reboot script** (required on some models — create triggered task in DSM Task Scheduler > Boot-up, run as root):

```bash
#!/bin/sh
if [ ! -c /dev/net/tun ]; then
  [ ! -d /dev/net ] && mkdir -m 755 /dev/net
  mknod /dev/net/tun c 10 200 && chmod 0755 /dev/net/tun
fi
if ! lsmod | grep -q "^tun\s"; then insmod /lib/modules/tun.ko; fi
```

### pfSense

NetBird has an official pfSense package. Key gotcha: pfSense's automatic outbound NAT randomizes source ports, breaking NAT traversal — configure a Static Port mapping rule.

```bash
fetch https://github.com/netbirdio/pfsense-netbird/releases/download/v0.1.2/netbird-0.55.1.pkg
fetch https://github.com/netbirdio/pfsense-netbird/releases/download/v0.1.2/pfSense-pkg-NetBird-0.1.0.pkg
pkg add -f netbird-0.55.1.pkg && pkg add -f pfSense-pkg-NetBird-0.1.0.pkg
```

Configure via VPN > NetBird in pfSense UI. For direct connections: Firewall > NAT > Outbound > Hybrid mode, add Static Port rule for NetBird host's UDP traffic on WAN.

### All Supported Platforms

| Platform | Install Method | Gotchas |
|----------|---------------|---------|
| macOS | Homebrew | None |
| Linux (any) | Install script | None |
| Windows | MSI installer | Run as admin |
| Docker | Container | `NET_ADMIN` + `SYS_ADMIN` caps required |
| Proxmox LXC | Install script | Needs `/dev/tun` passthrough in LXC config |
| Synology | Install script via SSH | May need reboot script for TUN device |
| pfSense | Official `.pkg` package | Static Port NAT rule needed for direct connections |
| OPNSense / TrueNAS | Install script | None |
| iOS / Android | App Store / Play Store | Mobile only, no setup key support |

Full install docs: https://docs.netbird.io/get-started/install

```bash
netbird status --detail  # show all peers, mesh IP, direct vs relayed connections
```

## aidevops Integration

### 1. AI Worker Mesh Provisioning

```bash
# Create reusable setup key for AI workers
curl -s -X POST "https://netbird.example.com/api/setup-keys" \
  -H "Authorization: Token <API_TOKEN>" -H "Content-Type: application/json" \
  -d '{"name":"aidevops-workers","type":"reusable","expires_in":604800,"auto_groups":["ai-workers"],"usage_limit":50}'

# Worker provisioning script
if command -v apt-get >/dev/null 2>&1; then
  curl -fsSL https://pkgs.netbird.io/install.sh | sh
elif command -v brew >/dev/null 2>&1; then
  brew install netbirdio/tap/netbird
fi
sudo netbird up --setup-key "$NETBIRD_SETUP_KEY" --management-url "https://netbird.example.com"
```

### 2. Access Control Groups

| Group | Members | Purpose |
|-------|---------|---------|
| `humans` | Developer machines | Full access to admin UIs |
| `ai-workers` | AI agent machines | Access to build/deploy services only |
| `build-servers` | CI/CD machines | Access to repos, registries, deploy targets |
| `production` | Production servers | Restricted — only deploy pipeline access |

### 3. Private DNS for Service Discovery

Configure DNS names in the NetBird dashboard:

```text
build01.netbird.cloud  -> 100.64.x.x  (build server)
gpu-node.netbird.cloud -> 100.64.x.x  (GPU compute)
coolify.netbird.cloud  -> 100.64.x.x  (deployment platform)
cloudron.netbird.cloud -> 100.64.x.x  (app platform)
```

### 4. API Automation

```bash
# List peers
curl -s "https://netbird.example.com/api/peers" \
  -H "Authorization: Token <API_TOKEN>" | jq '.[] | {name, ip, connected}'

# Create group
curl -s -X POST "https://netbird.example.com/api/groups" \
  -H "Authorization: Token <API_TOKEN>" -H "Content-Type: application/json" \
  -d '{"name": "ai-workers"}'

# Create access policy
curl -s -X POST "https://netbird.example.com/api/policies" \
  -H "Authorization: Token <API_TOKEN>" -H "Content-Type: application/json" \
  -d '{"name":"ai-workers-to-build","enabled":true,"rules":[{
    "name":"allow-build-access","enabled":true,
    "sources":["<ai-workers-group-id>"],"destinations":["<build-servers-group-id>"],
    "bidirectional":true,"protocol":"all","action":"accept"
  }]}'
```

### 5. Terraform Provider

```hcl
terraform {
  required_providers {
    netbird = { source = "netbirdio/netbird" }
  }
}

provider "netbird" {
  server_url = "https://netbird.example.com"
  token      = var.netbird_api_token
}

resource "netbird_group" "ai_workers" { name = "ai-workers" }

resource "netbird_setup_key" "workers" {
  name        = "aidevops-workers"
  type        = "reusable"
  auto_groups = [netbird_group.ai_workers.id]
}
```

## Cloudron Deployment

A Cloudron app package exists at https://github.com/marcusquinn/cloudron-netbird-app.

| Feature | Status | Notes |
|---------|--------|-------|
| Management server, Dashboard, Signal, Relay, STUN | Works | Combined `netbird-server` binary |
| PostgreSQL | Works | Cloudron add-on, auto-configured |
| Cloudron SSO (OIDC) | Works | Built-in OIDC provider, no Keycloak needed |
| Cloudron TURN relay | Works | Add-on, auto-configured for NAT traversal |
| **Reverse proxy** | **Not supported** | Requires Traefik with TLS passthrough; Cloudron uses nginx |

**Cloudron add-ons**: `postgresql`, `localstorage`, `oidc`, `turn`.

**OIDC integration**: Cloudron's OIDC add-on provides credentials registered as "Generic OIDC" in NetBird via REST API on startup. Requires a Personal Access Token stored at `/app/data/config/.admin_pat`.

**Reverse proxy limitation**: NetBird's reverse proxy feature requires Traefik with TLS passthrough. Cloudron's nginx terminates TLS before traffic reaches the app container — this is a fundamental architectural constraint, not a packaging issue. **Does not affect core mesh VPN functionality.**

## Comparison with Tailscale

| Feature | NetBird | Tailscale |
|---------|---------|-----------|
| Control plane | Self-hosted (AGPL) | Proprietary (Headscale as workaround) |
| REST API | Full, self-hosted | Full, cloud-hosted |
| SSO/MFA | Any OIDC provider (multiple simultaneous) | Google/Microsoft/GitHub |
| Reverse proxy | Yes (beta, self-hosted, requires Traefik) | Tailscale Funnel |
| Quantum resistance | Rosenpass | Not available |
| Vendor lock-in | None | High (proprietary control plane) |

**Use Tailscale instead**: Zero setup effort, don't mind vendor dependency, free tier (100 devices, 3 users) is sufficient.

**Use NetBird**: Full control, self-hosting, API automation, team scaling, or can't accept proprietary control plane.

## Reverse Proxy Feature (v0.65+, beta)

Exposes internal services on mesh peers to the public internet with automatic TLS and optional SSO/password/PIN authentication.

**How it works**: Create a "service" mapping a public domain to an internal peer + port → NetBird provisions TLS certificate + WireGuard tunnel → HTTPS requests terminated at NetBird proxy, forwarded through mesh.

**Requirements**: `netbirdio/netbird-proxy` container + **Traefik** (required for TLS passthrough) + DNS records for proxy domain.

**Key features**: Path-based routing, custom domains, HA (multiple proxy instances), ACME or static TLS certificates, hot reload.

**Limitations**: Requires Traefik (incompatible with nginx/Cloudron), no pre-shared keys or Rosenpass, beta (cloud support coming), not a replacement for Cloudflare Tunnel.

**Use when**: Exposing an internal service (e.g., Proxmox dashboard) to the internet without opening ports on the target machine.

## Troubleshooting

```bash
netbird status --detail          # check peer connections (direct vs relayed)
systemctl status netbird         # check daemon
journalctl -u netbird -f         # view client logs
docker compose logs -f netbird-server  # management server logs
netbird down && netbird up       # re-authenticate
netbird up --disable-auto-connect  # prevent auto-connect during debugging
netbird down && rm -rf /etc/netbird/ && netbird up --setup-key <KEY>  # reset client state
```

| Issue | Solution |
|-------|----------|
| Peers show "disconnected" | Check UDP 3478 is open; check WireGuard UDP firewall rules |
| Management server unreachable | Verify DNS, TLS certificate, Docker containers running |
| Setup key rejected | Key may be expired or usage limit reached — check dashboard |

## Resources

- **Docs**: https://docs.netbird.io
- **Self-Hosting Guide**: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- **Identity Providers**: https://docs.netbird.io/selfhosted/identity-providers
- **Reverse Proxy**: https://docs.netbird.io/manage/reverse-proxy
- **API Reference**: https://docs.netbird.io/api
- **Terraform Provider**: https://registry.terraform.io/providers/netbirdio/netbird/latest
- **GitHub**: https://github.com/netbirdio/netbird
- **Cloudron Package**: https://github.com/marcusquinn/cloudron-netbird-app
- **Forum**: https://forum.netbird.io
