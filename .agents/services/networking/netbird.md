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

### Proxmox Host

```bash
# Install on the Proxmox host itself (not in a VM)
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo netbird up --setup-key <SETUP_KEY>

# Optionally advertise the Proxmox subnet as a network route
# (allows mesh peers to reach VMs on the Proxmox bridge)
```

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
