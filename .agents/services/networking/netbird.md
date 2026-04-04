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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# NetBird - Self-Hosted Mesh VPN & Zero-Trust Networking

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Self-hosted WireGuard mesh VPN — SSO, MFA, granular ACLs, REST API, Terraform provider
- **vs Tailscale**: Fully self-hosted control plane (AGPL), no vendor lock-in, API-first
- **Install client**: `curl -fsSL https://pkgs.netbird.io/install.sh | sh`
- **CLI**: `netbird` | **Admin UI**: `https://netbird.example.com` | **API**: `https://netbird.example.com/api`
- **Docs**: https://docs.netbird.io | **License**: BSD-3 (client), AGPL-3.0 (server)

**Key concepts**: Management Server (state/ACLs) · Signal Server (WebRTC ICE) · Relay Server (TURN fallback) · Setup Key (bulk provisioning) · Peer Group (ACL target) · Network Route (subnet advertisement) · Private DNS (mesh name resolution)

<!-- AI-CONTEXT-END -->

## Self-Hosting

**Architecture**: Management (state/ACLs) + Signal (ICE) + Relay (TURN) → WireGuard P2P mesh. Data never flows through management server.

### Quickstart

Min: 1 vCPU / 2 GB RAM. Ports: TCP 80, 443 + **UDP 3478** (direct, not proxyable).

```bash
export NETBIRD_DOMAIN=netbird.example.com
NETBIRD_VERSION="v0.35.0"  # pin — check github.com/netbirdio/netbird/releases
curl -fsSL "https://github.com/netbirdio/netbird/releases/download/${NETBIRD_VERSION}/getting-started.sh" \
  -o /tmp/netbird-setup.sh
# Verify checksum from release page before running
bash /tmp/netbird-setup.sh
```

**DB**: SQLite (default, <50 peers, no HA) or PostgreSQL (production, HA). **IdP**: Embedded Dex (quickstart); production: any OIDC — Keycloak, Zitadel, Authentik, PocketID, Google Workspace, Entra ID, Okta, Auth0. Cloudron: built-in OIDC works directly. **JWT Group Sync**: Settings > Groups > JWT group sync → claim name (usually `groups`).

### Critical Gotchas

1. **UDP 3478 cannot be proxied** — STUN requires direct UDP
2. **SQLite = single instance** — no HA without PostgreSQL
3. **Encryption key** — `server.store.encryptionKey` encrypts tokens at rest; losing it requires regenerating all keys
4. **Single account mode** is default — disable with `--disable-single-account-mode` for multi-tenant
5. **`/setup` page disappears** after first user — save admin credentials immediately
6. **Hetzner Robot firewall is stateless** — may need ephemeral UDP range open; Hetzner Cloud is stateful
7. **Oracle Cloud blocks UDP 3478** by default in both Security Rules and iptables

## Deployment Options

### Standalone VPS

**Sizing**: 1-25 peers → 1 vCPU / 2 GB (~$4-6/mo Hetzner CX22); 25-100 peers → 2 vCPU / 4 GB. **DNS**: A `netbird` → server IP; optional CNAME `proxy` + `*.proxy` → `netbird.example.com`. **Post-install**: Open dashboard, create admin on `/setup`, create PAT (Settings > Personal Access Tokens), create setup keys.

```bash
# Health check
curl -s "https://netbird.example.com/api/instance/version" -H "Authorization: Token <PAT>" | jq .

# Upgrade
docker compose exec netbird-server cat /var/lib/netbird/store.db > backup-$(date +%F).db 2>/dev/null || true
docker compose pull netbird-server dashboard && docker compose up -d --force-recreate netbird-server dashboard
```

### Coolify / Dokploy (Traefik-based PaaS)

Full feature parity with standalone. Generate config with `[1] Existing Traefik`, adapt compose: remove Traefik service, add labels to dashboard, expose `3478:3478/udp`.

```yaml
# netbird-server: ports: ["3478:3478/udp"]
# dashboard:
traefik.enable: "true"
traefik.http.routers.netbird-dashboard.rule: "Host(`netbird.example.com`)"
traefik.http.routers.netbird-dashboard.tls.certresolver: "letsencrypt"
traefik.http.services.netbird-dashboard.loadbalancer.server.port: "80"
# netbird-proxy (optional):
traefik.tcp.routers.netbird-proxy-tls.rule: "HostSNI(`*.proxy.netbird.example.com`)"
traefik.tcp.routers.netbird-proxy-tls.tls.passthrough: "true"
```

Dokploy: identical, use `../files/` prefix for bind mount persistence.

### Cloudron

Package: https://github.com/marcusquinn/cloudron-netbird-app. Add-ons: `postgresql`, `localstorage`, `oidc`, `turn`.

**Reverse proxy not supported** — requires Traefik TLS passthrough; Cloudron uses nginx (architectural constraint). Core mesh VPN unaffected.

### Feature Comparison

| Feature | Cloudron | Standalone VPS | Coolify/Dokploy |
|---------|----------|----------------|-----------------|
| Mesh VPN + Dashboard + API | Yes | Yes | Yes |
| SSO (OIDC) | Cloudron SSO | Any IdP | Any IdP |
| PostgreSQL | Add-on | Manual | PaaS DB |
| **Reverse proxy** | **No** | Yes | **Yes** |

## Client Installation

```bash
# macOS
brew install netbirdio/tap/netbird && sudo netbird up

# Linux / Raspberry Pi / Proxmox host
curl -fsSL https://pkgs.netbird.io/install.sh | sh
sudo systemctl enable --now netbird && sudo netbird up --setup-key <KEY>

# Docker
docker run -d --name netbird --cap-add NET_ADMIN --cap-add SYS_ADMIN \
  -v netbird-client:/etc/netbird netbirdio/netbird:v0.35.0 \
  up --setup-key <SETUP_KEY> --management-url https://netbird.example.com

# Synology (SSH)
curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh && sudo netbird up --setup-key <KEY>
```

| Platform | Gotchas |
|----------|---------|
| macOS (Homebrew) | None |
| Linux / ARM / Proxmox host | None |
| Windows (MSI) | Run as admin |
| Docker (`NET_ADMIN` + `SYS_ADMIN`) | Caps required |
| Proxmox LXC | Add `/dev/tun` passthrough to `/etc/pve/lxc/<CTID>.conf` |
| Synology (SSH) | Create TUN device reboot script in DSM Task Scheduler |
| pfSense (official `.pkg`) | Static Port NAT rule (Firewall > NAT > Outbound > Hybrid) |
| OPNSense / TrueNAS | None |
| iOS / Android (App Store / Play Store) | No setup key support |

## aidevops Integration

### Worker Provisioning

```bash
# Create reusable setup key for AI workers
curl -s -X POST "https://netbird.example.com/api/setup-keys" \
  -H "Authorization: Token <API_TOKEN>" -H "Content-Type: application/json" \
  -d '{"name":"aidevops-workers","type":"reusable","expires_in":604800,"auto_groups":["ai-workers"],"usage_limit":50}'
# Then install client and: sudo netbird up --setup-key "$NETBIRD_SETUP_KEY"
```

### Access Control Groups

| Group | Members | Access |
|-------|---------|--------|
| `humans` | Developer machines | Full admin UIs |
| `ai-workers` | AI agent machines | Build/deploy services only |
| `build-servers` | CI/CD machines | Repos, registries, deploy targets |
| `production` | Production servers | Deploy pipeline only |

### API Automation

Base URL: `https://netbird.example.com/api` | Auth: `-H "Authorization: Token <TOKEN>"`

```bash
# List peers
curl -s .../api/peers -H "Authorization: Token <TOKEN>" | jq '.[] | {name,ip,connected}'
# Create group: POST /api/groups  {"name":"ai-workers"}
# Create policy: POST /api/policies  {"name":"...","enabled":true,"rules":[{"sources":["<group-id>"],"destinations":["<group-id>"],"bidirectional":true,"protocol":"all","action":"accept"}]}
```

### Terraform

Provider: `netbirdio/netbird` (registry.terraform.io). Resources: `netbird_group`, `netbird_setup_key`, `netbird_policy`, `netbird_route`, `netbird_dns`. Configure with `server_url` + `token`.

## Reverse Proxy Feature (v0.65+, beta)

Exposes internal mesh services publicly with automatic TLS and optional SSO/password/PIN auth. Maps public domain → internal peer + port → HTTPS terminated at proxy, forwarded through mesh.

**Requires**: `netbirdio/netbird-proxy` + Traefik (TLS passthrough) + DNS for proxy domain. **Features**: Path routing, custom domains, HA, ACME or static TLS, hot reload. **Limitations**: Traefik only (no nginx/Cloudron), no Rosenpass, beta.

## vs Tailscale

| Feature | NetBird | Tailscale |
|---------|---------|-----------|
| Control plane | Self-hosted (AGPL) | Proprietary |
| SSO | Any OIDC (multiple simultaneous) | Google/Microsoft/GitHub |
| Reverse proxy | Yes (beta, Traefik) | Tailscale Funnel |
| Quantum resistance | Rosenpass | No |
| Vendor lock-in | None | High |

**Use Tailscale**: Zero setup, vendor dependency acceptable, free tier (100 devices, 3 users) sufficient.
**Use NetBird**: Full control, API automation, team scaling, or proprietary control plane unacceptable.

## Troubleshooting

```bash
netbird status --detail          # peer connections (direct vs relayed)
journalctl -u netbird -f         # client logs
docker compose logs -f netbird-server  # server logs
netbird down && netbird up       # re-authenticate
netbird down && rm -rf /etc/netbird/ && netbird up --setup-key <KEY>  # reset
```

| Issue | Solution |
|-------|---------|
| Peers disconnected | UDP 3478 open? WireGuard UDP firewall rules? |
| Management unreachable | DNS, TLS cert, Docker containers running? |
| Setup key rejected | Expired or usage limit reached — check dashboard |

## Resources

- https://docs.netbird.io (docs, API, IdP, reverse proxy, self-hosting)
- https://github.com/netbirdio/netbird
- https://github.com/marcusquinn/cloudron-netbird-app (Cloudron package)
