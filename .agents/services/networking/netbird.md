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
- **Control**: Self-hostable control plane and API automation; assess licence/feature gates and migration costs rather than promising zero lock-in
- **Admin UI**: `https://netbird.example.com` | **API**: `https://netbird.example.com/api`
- **Client onboarding**: use the current package-store or vendor instructions for the selected client version; configure the self-hosted management URL before enrolling
- **Docs**: https://docs.netbird.io | **Licences**: BSD-3-Clause generally; management, signal, and relay directories AGPLv3; check the selected release and commercial features
- **Optional GitHub ingress**: [Webhook onboarding](../../reference/github-webhook-onboarding.md) — mesh access alone is private; public webhook delivery needs separate ingress and preserved GitHub HMAC. Polling remains the default
- **Host selection**: [OS recommendations](../../reference/os-selection.md) — verify Docker/client support and architecture before preferring ARM, Rocky, or Alpine; Cloudron's Ubuntu x64 requirement is separate

**Key concepts**: Management Server (state/ACLs) · Signal Server (WebRTC ICE) · Relay Server (TURN fallback) · Setup Key (bulk provisioning) · Peer Group (ACL target) · Network Route (subnet advertisement) · Private DNS (mesh name resolution)

<!-- AI-CONTEXT-END -->

## Self-Hosting

**Architecture**: Management (state/ACLs) + Signal (ICE) + Relay (TURN) → WireGuard P2P mesh. Data never flows through management server.

### Quickstart

Min: 1 vCPU / 2 GB RAM. Ports: TCP 80, 443 + **UDP 3478** (direct, not proxyable).

Follow the current [self-hosted quickstart](https://docs.netbird.io/selfhosted/selfhosted-quickstart)
and select a compatible stable [release](https://github.com/netbirdio/netbird/releases).
Review downloaded setup assets before execution and pin the chosen versions;
do not reuse an old `v0.35.0` example for today's reverse-proxy features.

**DB**: SQLite (default, <50 peers, no HA) or PostgreSQL (production, HA). **IdP**: Embedded Dex (quickstart); production: any OIDC — Keycloak, Zitadel, Authentik, PocketID, Google Workspace, Entra ID, Okta, Auth0. Cloudron's optional SSO is an external-provider onboarding path, not automatic: preserve the embedded first-owner login and configure/link identities only through the documented package/dashboard flow. **JWT Group Sync**: verify the selected IdP's claims and current NetBird release before enabling it.

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

Use the current [external reverse-proxy guide](https://docs.netbird.io/selfhosted/external-reverse-proxy).
Choose its existing-Traefik path and adapt the release's Compose routing and UDP
exposure. Feature parity depends on the actual proxy, versions, configuration,
and licence; a running dashboard alone does not prove native ingress works.

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

Package source: https://github.com/marcusquinn/cloudron-netbird-app. Its baseline
requires `postgresql`, `localstorage`, and `tls`; inspect the installed manifest
for optional identity-provider add-ons. The package combines management, signal,
relay, and STUN, with Cloudron HTTPS for the dashboard plus selected dedicated
native TCP and STUN UDP ports. Verify the installed package release and selected
ports rather than copying defaults.

The package supports the core private mesh. Do not claim Cloudron SSO is
configured merely because `optionalSso` is available, and do not treat Cloudron
TURN as an interchangeable NetBird relay/STUN service. The 2.1.0 source includes
an optional bundled public proxy with second-IPv4/raw-TLS ingress, documented in
the package's `REVERSE-PROXY.md`. Source availability, release availability,
installed configuration and production qualification are distinct: verify each,
rather than treating a merged feature as tested on every host. Keep normal
authenticated dashboard/native endpoints separate from public service ingress;
do not replace Cloudron's managed proxy or publicly expose SSH, desktop sharing,
SMB or raw administration ports through this feature.

#### Multiple Cloudron instances

| Use case | Additional public IPv4 | Guidance |
|----------|------------------------|----------|
| Another private mesh and dashboard | None per app | Share primary IP; unique app hostname, native TCP port and STUN UDP port |
| Many public HTTPS services in one mesh | One proxy ingress IP | Service subdomains share that proxy's HTTPS listener |
| Independent public proxies for several meshes | Separate ingress IPs are the simpler design | Requires multi-instance host tooling first; not supported by rerunning today's helper |
| Several proxies sharing one ingress IP | Potentially one, with an SNI gateway | Future design, not implemented/qualified support |

Recommend private-only instances first; do not buy Floating IPs for ordinary peer
access or per published service. On Hetzner Cloud the optional ingress address is
a Floating IPv4. Each instance needs separate users, keys, policies and backups.
Shared SSO does not federate meshes. Verify client profile/simultaneous-connection
capabilities and mesh/LAN address overlap before designing cross-instance access.

The current `scripts/netbird-ingress.py` in the package has fixed config storage,
nftables table/tag, address label, lock and systemd unit names. Another IP alone
does not make it safe for a second instance. Do not overwrite its configuration,
rename only a unit, widen trust to the Docker subnet or disable backend guards.
Multi-instance support needs scoped resources, independent reconciliation/rollback
and collision/isolation tests. Each proxy must retain its dedicated trusted
PROXY-v2 source identity. Consult the package's `MULTI-INSTANCE.md` when available
in the selected release, plus `REVERSE-PROXY.md` and `test/QUALIFICATION.md`.

A shared-IP alternative would require TLS-passthrough SNI routing by approved
brand domains, ACME TLS-ALPN-01 compatibility, trustworthy client-IP forwarding,
unknown-name rejection and cross-instance isolation tests. It adds a shared
gateway failure/trust boundary; do not present it as a working installation path.
Separate Cloudron apps still share VPS root control and the host failure domain;
use separate infrastructure for stronger client isolation or independent ownership.

### Feature Comparison

| Feature | Cloudron | Standalone VPS | Coolify/Dokploy |
|---------|----------|----------------|-----------------|
| Mesh VPN + Dashboard + API | Yes | Yes | Yes |
| SSO (OIDC) | Optional external-provider setup; preserve embedded owner | Any IdP | Any IdP |
| PostgreSQL | Add-on | Manual | PaaS DB |
| **Native Reverse Proxy (beta)** | Optional second-IP host setup; verify installed release and qualification | Compatible proxy deployment required | Compatible Traefik configuration required |

## Client Installation

### Personal Macs, phones, and off-LAN access

1. In the dashboard's **Peers** area, enrol each desktop through interactive
   sign-in where practical. Use a short-lived, usage-limited setup key only for
   unattended devices; scope it to the intended group and store it in a supported
   secret store. Do not paste keys into tickets, shell history, or agent output.
2. Install the current desktop or mobile client from its supported source and
   enter the exact self-hosted management URL. For the Cloudron package, that is
   the selected native TCP management URL, not just the browser dashboard URL.
   Mobile clients may require an interactive browser login; confirm the current
   mobile client's self-hosted and profile capabilities instead of assuming setup
   keys or multiple profiles work the same way as desktop clients.
3. Confirm the peer receives its assigned mesh IP and private DNS name, then test
   from mobile data or another genuinely off-LAN connection. Inspect `netbird
   status --detail` to distinguish direct from relayed encrypted traffic; relay
   use is a reachability fallback, not a loss of WireGuard encryption.
4. Remote Mac access still requires the Mac's SSH, Screen Sharing, or SMB service,
   an allowed local user, firewall rules, and narrowly scoped mesh policy. Account
   for sleep, restart/startup, FileVault preboot, and client/VPN conflicts. Phones
   can suspend background networking; do not promise always-on remote wake or
   background operation. Do not add router port forwarding for private mesh use.

### Policy and topology boundaries

| Need | Boundary and recommendation |
|------|-----------------------------|
| Direct peer access | Default for named devices; grant only required groups, ports, and protocols. |
| Subnet routing | Explicitly authorize a router peer and non-overlapping LAN prefixes; it extends access to a LAN and is not automatic peer access. |
| Exit node | Opt-in internet egress via a trusted peer; it is not a way to publish a service. |
| Public HTTPS ingress | A separately operated proxy terminates public TLS and forwards only an approved HTTP service; it does not inherit Cloudron HTTP protection. Preserve application signatures for webhooks. |

Use least-privilege groups such as administrators, personal devices, support, and
service peers; review effective policies because a broad rule can override the
intent of a narrow one. Separate organisations or independent brands should use
separate NetBird instances and administration boundaries. They do not federate:
cross-instance access needs an explicitly designed gateway, not shared setup
keys. On a shared host, plan unique native/STUN ports, distinct proxy ingress,
address-range overlap, profile/version limits, and the resulting shared host,
backup, and failure-domain trust.

| Platform | Gotchas |
|----------|---------|
| macOS | Confirm the current client supports the installed OS and the intended self-hosted profile/login flow |
| Linux / ARM / Proxmox host | Confirm architecture, TUN, service, and selected client release support |
| Windows (MSI) | Run as admin |
| Docker (`NET_ADMIN` + `SYS_ADMIN`) | Caps required |
| Proxmox LXC | Add `/dev/tun` passthrough to `/etc/pve/lxc/<CTID>.conf` |
| Synology (SSH) | Create TUN device reboot script in DSM Task Scheduler |
| pfSense (official `.pkg`) | Static Port NAT rule (Firewall > NAT > Outbound > Hybrid) |
| OPNSense / TrueNAS | None |
| iOS / Android | Verify self-hosted login, background, and profile behaviour in the installed app version |

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

## Native Reverse Proxy Feature (beta)

Exposes internal mesh services publicly with automatic TLS and optional SSO/password/PIN auth. Maps public domain → internal peer + port → HTTPS terminated at proxy, forwarded through mesh.

For self-hosting, follow [Enable Reverse Proxy](https://docs.netbird.io/selfhosted/migration/enable-reverse-proxy)
for the `netbirdio/reverse-proxy` component, token, DNS, and ACME configuration.
The supported external front-proxy integration is currently Traefik; this is not
a ban on an ordinary Caddy/nginx gateway using mesh transport independently.

Creating services requires **Services** permission (Network Admin or higher).
Public HTTP services can deliberately disable additional proxy authentication
and rely on the application's own authentication. For GitHub, preserve
`X-Hub-Signature-256`; static Header Auth is not compatible with GitHub's dynamic
HMAC signature and strips its matched header. Browser SSO/password/PIN and
NetBird-Only Access are not GitHub webhook delivery paths. Use the step-by-step
[optional webhook guide](../../reference/github-webhook-onboarding.md).

Some self-hosted enterprise features, including SCIM, require a commercial licence;
check [self-hosted versus cloud](https://docs.netbird.io/about-netbird/self-hosted-vs-cloud)
and current plan terms. Do not claim that every self-hosted feature is free or
that native Reverse Proxy has a paid gate without evidence for that deployment.

## vs Tailscale

| Feature | NetBird | Tailscale |
|---------|---------|-----------|
| Control plane | Self-hosted (AGPL) | Proprietary |
| SSO | Any OIDC (multiple simultaneous) | Google/Microsoft/GitHub |
| Reverse proxy | Yes (beta, Traefik) | Tailscale Funnel |
| Quantum resistance | Rosenpass | No |
| Exit considerations | Self-hosted control; maintain identity/config/data migration plans | Hosted control-plane dependency; evaluate export and migration paths |

**Use Tailscale**: Zero setup, vendor dependency acceptable, free tier (100 devices, 3 users) sufficient.
**Use NetBird**: Full control, API automation, team scaling, or proprietary control plane unacceptable.

## Troubleshooting

```bash
netbird status --detail          # peer connections (direct vs relayed)
journalctl -u netbird -f         # client logs where systemd manages the client
netbird down && netbird up       # re-authenticate through the supported client flow
```

Before recovery, retain a verified embedded owner/admin path and capture the
specific client error. Use the selected platform's supported logout, repair, or
re-enrolment documentation; do not delete client state, reset the server, or copy
live SQLite data as a generic fix. Keep server keys and credentials in Cloudron
backups and supported secure stores.

| Issue | Solution |
|-------|---------|
| Peers disconnected | UDP 3478 open? WireGuard UDP firewall rules? |
| Management unreachable | DNS, TLS cert, Docker containers running? |
| Setup key rejected | Expired or usage limit reached — check dashboard |

## Resources

- https://docs.netbird.io (docs, API, IdP, reverse proxy, self-hosting)
- https://github.com/netbirdio/netbird
- https://github.com/marcusquinn/cloudron-netbird-app (Cloudron package)
