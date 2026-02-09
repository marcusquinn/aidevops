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
- **Install**: `brew install tailscale` (macOS) or `curl -fsSL https://tailscale.com/install.sh | sh` (Linux)
- **CLI**: `tailscale` (control) + `tailscaled` (daemon)
- **Admin**: https://login.tailscale.com/admin
- **Docs**: https://tailscale.com/kb
- **Free tier**: Up to 100 devices, 3 users

**Key Concepts**:

- **Tailnet**: Your private mesh network (all your devices)
- **MagicDNS**: Automatic DNS names for devices (e.g., `my-vps.tail1234.ts.net`)
- **Serve**: Expose a local port to your tailnet via HTTPS
- **Funnel**: Expose a local port to the public internet via HTTPS
- **ACLs**: Access control lists defining who can reach what

<!-- AI-CONTEXT-END -->

## Installation

### macOS

```bash
# Via Homebrew (open-source variant, required for Funnel)
brew install tailscale

# Start daemon
sudo tailscaled &

# Authenticate
tailscale up
```

Or install the App Store version (GUI, but Funnel requires the open-source variant).

### Linux (VPS)

```bash
# One-line install
curl -fsSL https://tailscale.com/install.sh | sh

# Enable and start
sudo systemctl enable --now tailscaled

# Authenticate
sudo tailscale up

# Verify
tailscale status
```

### Verify Connection

```bash
# Show all devices on your tailnet
tailscale status

# Check your Tailscale IP
tailscale ip -4

# Ping another device
tailscale ping <device-name>
```

## Common Use Cases with aidevops

### 1. Secure OpenClaw Gateway Access

Run OpenClaw on a VPS, access it securely from any device:

```bash
# On VPS: Configure OpenClaw with Tailscale Serve
# In ~/.openclaw/openclaw.json:
```

```json5
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" },
    auth: { mode: "token", token: "your-token" },
  },
}
```

```bash
# Access from any tailnet device:
# https://<vps-magicdns>/
```

### 2. SSH to VPS Without Port Forwarding

```bash
# On VPS: Tailscale is already running
# From laptop:
ssh user@<vps-tailscale-hostname>

# No need to open port 22 to the internet
```

### 3. Access Self-Hosted Services

Connect to Coolify, Cloudron, or other self-hosted dashboards without exposing them publicly:

```bash
# Access Coolify dashboard on VPS via tailnet
# https://<vps-magicdns>:8000
```

## Tailscale Serve

Expose a local service to your tailnet with automatic HTTPS:

```bash
# Expose local port 18789 (OpenClaw gateway)
tailscale serve https / http://127.0.0.1:18789

# Verify
tailscale serve status

# Remove
tailscale serve reset
```

**Requirements**: HTTPS must be enabled for your tailnet (the CLI prompts if missing).

**Identity headers**: Serve injects `tailscale-user-login` headers, allowing services to identify the connecting user without separate auth.

## Tailscale Funnel

Expose a local service to the public internet:

```bash
# Expose to public internet
tailscale funnel https / http://127.0.0.1:18789

# Verify
tailscale funnel status
```

**Requirements**: Tailscale v1.38.3+, MagicDNS enabled, HTTPS enabled, funnel node attribute. Only ports 443, 8443, 10000 over TLS. macOS requires the open-source Tailscale variant (Homebrew, not App Store).

**Security**: Funnel exposes to the entire internet. Always use strong auth (password/token) when using Funnel.

## ACLs (Access Control)

Configure who can access what in your tailnet at https://login.tailscale.com/admin/acls:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["*:*"]
    }
  ],
  "tagOwners": {
    "tag:server": ["autogroup:admin"]
  }
}
```

### Recommended ACL for OpenClaw VPS

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:server:18789"]
    }
  ]
}
```

This restricts access to only the OpenClaw gateway port on tagged servers.

## Integration with aidevops Infrastructure

### Provisioning a VPS with Tailscale

When using `@hetzner` or `@hostinger` to provision a VPS:

1. Provision the server via the hosting agent
2. SSH in and install Tailscale
3. Tag the node (e.g., `tag:server`)
4. Install OpenClaw or other services
5. Configure Tailscale Serve for HTTPS access

### Tailscale + Cloudflare

For custom domains pointing to Tailscale Funnel:

1. Set up Funnel on the target machine
2. Create a CNAME record in Cloudflare pointing to your Funnel hostname
3. Disable Cloudflare proxy (grey cloud) since Tailscale handles TLS

## Troubleshooting

```bash
# Check connection status
tailscale status

# Check if daemon is running
tailscale debug daemon-status

# View logs (macOS)
log show --predicate 'process == "tailscaled"' --last 5m

# View logs (Linux)
journalctl -u tailscaled -f

# Re-authenticate
tailscale up --reset

# Check network connectivity
tailscale netcheck
```

## Resources

- **Docs**: https://tailscale.com/kb
- **Serve**: https://tailscale.com/kb/1312/serve
- **Funnel**: https://tailscale.com/kb/1223/tailscale-funnel
- **ACLs**: https://tailscale.com/kb/1018/acls
- **Pricing**: https://tailscale.com/pricing (free tier: 100 devices, 3 users)
