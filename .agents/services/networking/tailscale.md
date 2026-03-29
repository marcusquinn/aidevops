---
description: Tailscale - Zero-config mesh VPN for secure device networking
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

# Tailscale - Mesh VPN & Secure Networking

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Zero-config mesh VPN connecting devices securely without port forwarding
- **Install**: `brew install tailscale` (macOS) | `curl -fsSL https://tailscale.com/install.sh | sh` (Linux)
- **CLI**: `tailscale` (control) + `tailscaled` (daemon)
- **Admin**: https://login.tailscale.com/admin
- **Docs**: https://tailscale.com/kb
- **Free tier**: 100 devices, 3 users

**Key Concepts**: **Tailnet** = your private mesh network. **MagicDNS** = auto DNS (e.g., `my-vps.tail1234.ts.net`). **Serve** = expose local port to tailnet via HTTPS. **Funnel** = expose to public internet via HTTPS. **ACLs** = access control lists.

<!-- AI-CONTEXT-END -->

## Installation

### macOS

```bash
brew install tailscale          # Open-source variant (required for Funnel)
sudo tailscaled &               # Start daemon
tailscale up                    # Authenticate
```

App Store version available (GUI only, no Funnel support).

### Linux

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up
tailscale status                # Verify
```

### Status Commands

```bash
tailscale status                # All devices on tailnet
tailscale ip -4                 # Your Tailscale IP
tailscale ping <device-name>    # Ping another device
```

## Tailscale Serve

Expose a local service to your tailnet with automatic HTTPS:

```bash
tailscale serve https / http://127.0.0.1:18789
tailscale serve status          # Verify
tailscale serve reset           # Remove
```

HTTPS must be enabled for your tailnet. Serve injects `tailscale-user-login` headers for user identification without separate auth.

## Tailscale Funnel

Expose a local service to the **public internet**:

```bash
tailscale funnel https / http://127.0.0.1:18789
tailscale funnel status
```

**Requirements**: v1.38.3+, MagicDNS enabled, HTTPS enabled, funnel node attribute. Ports: 443, 8443, 10000 (TLS only). macOS requires Homebrew variant (not App Store).

**Security**: Funnel exposes to the entire internet — always use strong auth (password/token).

## ACLs (Access Control)

Configure at https://login.tailscale.com/admin/acls:

```json
{
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["*:*"] }
  ],
  "tagOwners": {
    "tag:server": ["autogroup:admin"]
  }
}
```

Restrict to specific ports by replacing `"dst": ["*:*"]` with e.g. `["tag:server:18789"]` (OpenClaw gateway only).

## Common Use Cases

### Secure OpenClaw Gateway

Run OpenClaw on a VPS, access via tailnet. In `~/.openclaw/openclaw.json`:

```json5
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" },
    auth: { mode: "token", token: "your-token" },
  },
}
```

Access from any tailnet device: `https://<vps-magicdns>/`

### SSH Without Port Forwarding

```bash
ssh user@<vps-tailscale-hostname>   # No port 22 exposed to internet
```

### Self-Hosted Dashboards

Access Coolify, Cloudron, etc. without public exposure: `https://<vps-magicdns>:8000`

## Integration with aidevops

### VPS Provisioning

1. Provision server via `@hetzner` or `@hostinger`
2. Install Tailscale, tag node (`tag:server`)
3. Install services, configure Tailscale Serve for HTTPS

### Tailscale + Cloudflare (Custom Domains)

1. Set up Funnel on target machine
2. CNAME in Cloudflare → Funnel hostname
3. Disable Cloudflare proxy (grey cloud) — Tailscale handles TLS

## Troubleshooting

```bash
tailscale status                # Connection status
tailscale debug daemon-status   # Daemon health
tailscale netcheck              # Network connectivity
tailscale up --reset            # Re-authenticate
```

**Logs**: macOS: `log show --predicate 'process == "tailscaled"' --last 5m` | Linux: `journalctl -u tailscaled -f`

## Resources

- [Docs](https://tailscale.com/kb) · [Serve](https://tailscale.com/kb/1312/serve) · [Funnel](https://tailscale.com/kb/1223/tailscale-funnel) · [ACLs](https://tailscale.com/kb/1018/acls) · [Pricing](https://tailscale.com/pricing)
