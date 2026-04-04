<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Tunnel

Outbound-only connectivity from origin to Cloudflare — no inbound ports, no firewall exposure, no public IP required.

## Architecture

`Tunnel` (named, persistent object) → `cloudflared` connector(s) → origin service(s)

- **Public hostname routing**: expose HTTP, HTTPS, SSH, or gRPC services through Cloudflare
- **Private routing**: publish private CIDRs for WARP-connected users
- **Zero Trust**: pair hostnames with Access policies instead of opening the origin directly

## Quick start

```bash
brew install cloudflared               # macOS; use distro package manager elsewhere
cloudflared tunnel login               # authorize this machine
cloudflared tunnel create my-tunnel    # creates named tunnel + credentials file
cloudflared tunnel route dns my-tunnel app.example.com
cloudflared tunnel run my-tunnel
```

## Core commands

```bash
cloudflared tunnel create <name>
cloudflared tunnel list
cloudflared tunnel info <name>
cloudflared tunnel delete <name>

cloudflared tunnel route dns <tunnel> <hostname>
cloudflared tunnel route list
cloudflared tunnel route ip add 10.0.0.0/8 <tunnel>

cloudflared tunnel run <name>
```

## Config skeleton

```yaml
# ~/.cloudflared/config.yml
tunnel: 6ff42ae2-765d-4adf-8112-31c55c1551ef
credentials-file: /root/.cloudflared/6ff42ae2-765d-4adf-8112-31c55c1551ef.json

ingress:
  - hostname: app.example.com
    service: http://localhost:8000
  - hostname: api.example.com
    service: https://localhost:8443
    originRequest:
      noTLSVerify: true # dev only; prefer valid TLS in production
  - service: http_status:404
```

## Operating notes

- Prefer remotely managed tunnels and Access policies for sensitive services.
- Multiple connectors per named tunnel = HA; Cloudflare load-balances automatically.
- Ingress rules are first-match-wins; always end with a catch-all (`http_status:404`).
- Long-lived connections may drop on connector restart or replica replacement.

## Related docs

- [Tunnel patterns](./tunnel-patterns.md) - Docker, Kubernetes, HA, service types, use cases
- [Tunnel gotchas](./tunnel-gotchas.md) - troubleshooting, limits, operational guardrails
