---
description: Web hosting provider comparison and setup
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Web Hosting Helper

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Local domain management for ~/Git projects with SSL
- **Script**: `.agents/scripts/webhosting-helper.sh`
- **Config**: `configs/webhosting-config.json`
- **Requires**: LocalWP or nginx, OpenSSL, sudo access

**Commands**: `setup|list|remove`
**Usage**: `./.agents/scripts/webhosting-helper.sh setup PROJECT_NAME [PORT]`

**Frameworks** (auto-detected):

| Framework | Default Port | HMR |
|-----------|-------------|-----|
| Next.js / React / Vue / Nuxt | 3000 | Yes |
| Vite / Svelte | 5173 | Yes |
| Rails | 3000 | No |
| Python / PHP | 8000 | No |
| Go | 8080 | No |

**SSL Certs**: `~/.localhost-setup/certs/` (self-signed, 2048-bit RSA, 365 days, TLSv1.2+1.3)

**CRITICAL**: After setup, manually add to hosts:

```bash
echo "127.0.0.1 PROJECT.local" | sudo tee -a /etc/hosts
```

<!-- AI-CONTEXT-END -->

Local domain management for web applications in `~/Git`, with automatic framework detection and SSL certificate generation.

## Prerequisites

- **LocalWP** (recommended) or standalone nginx
- **OpenSSL** for certificate generation
- **sudo access** for hosts file modification

## Setup

```bash
# 1. Copy configuration
cp configs/webhosting-config.json.txt configs/webhosting-config.json

# 2. Make script executable
chmod +x .agents/scripts/webhosting-helper.sh
```

## Usage

```bash
# Auto-detect framework and port
./.agents/scripts/webhosting-helper.sh setup myapp

# Specify custom port
./.agents/scripts/webhosting-helper.sh setup myapp 3001

# List configured domains
./.agents/scripts/webhosting-helper.sh list

# Remove a domain
./.agents/scripts/webhosting-helper.sh remove myapp
```

## Complete Setup Workflow

Follow these exact steps (also applies to AI agent setup):

```bash
# 1. Setup domain (creates nginx config + SSL certs)
./.agents/scripts/webhosting-helper.sh setup myapp 3000

# 2. CRITICAL: Add to hosts file (requires sudo — run in separate terminal)
echo "127.0.0.1 myapp.local" | sudo tee -a /etc/hosts

# 3. Start development server
cd ~/Git/myapp
PORT=3000 npm run dev    # or pnpm dev, yarn dev

# 4. Visit https://myapp.local
#    - Click "Proceed" on the self-signed cert warning (expected)
#    - Verify: HTTP redirects to HTTPS, hot reload works
```

## LocalWP Integration

Works alongside LocalWP's nginx router — automatic detection, no conflicts with WordPress sites, preserves hot reload.

## Directory Structure

```text
~/.localhost-setup/
├── certs/
│   ├── myapp.local.crt
│   ├── myapp.local.key
│   └── ...

~/Library/Application Support/Local/run/router/nginx/conf/
├── route.myapp.local.conf
└── ...

/etc/hosts
127.0.0.1 myapp.local
```

## Troubleshooting

**Domain not resolving** ("This site can't be reached"):
Missing hosts entry — `echo "127.0.0.1 PROJECT.local" | sudo tee -a /etc/hosts`

**LocalWP not found**:
Install from <https://localwp.com/> or use standalone nginx (manual config required).

**Port already in use**:

```bash
lsof -i :3000                                          # Find what's using it
./.agents/scripts/webhosting-helper.sh setup myapp 3001  # Use different port
```

**SSL certificate issues**:

```bash
rm ~/.localhost-setup/certs/myapp.local.*
./.agents/scripts/webhosting-helper.sh setup myapp       # Regenerate
```

**Build errors** (frameworks requiring build steps):

```bash
cd ~/Git/PROJECT_NAME
pnpm build              # Generate required files first
PORT=PORT_NUMBER pnpm dev
```

**Browser certificate warnings**:
Self-signed certs trigger warnings on first access. Chrome/Safari: "Advanced" → "Proceed". Firefox: "Advanced" → "Accept the Risk".

## Related Documentation

- [LocalWP Integration](LOCALHOST.md)
- [SSL Certificate Management](SECURITY.md)
- [Nginx Configuration](../configs/webhosting-config.json.txt)
