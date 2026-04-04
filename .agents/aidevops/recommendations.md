---
description: Best practices and provider selection guide
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Best Practices & Provider Selection Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Hosting**: Hostinger ($, small sites), Hetzner ($$, production), Closte ($$, VPS)
- **Deployment**: Coolify (self-hosted PaaS), Cloudron (easy app management)
- **DNS**: Cloudflare (CDN/security), Spaceship (modern), 101domains (large portfolios), Route 53 (AWS)
- **Security**: API tokens in `~/.config/aidevops/`, never in repo, rotate quarterly
- **SSH**: Ed25519 keys, standardize across servers, passphrase protection
- **Local Dev**: `.local` suffix, SSL by default, port ranges (WordPress 10000+, APIs 8000+, MCP 8080+)
- **MCP Ports**: Sequential allocation starting from base 8081
- **Monitoring**: Weekly status checks, monthly token rotation, quarterly audits

<!-- AI-CONTEXT-END -->

## Provider Selection

### Hosting & Cloud

| Provider | Best For | Price | Key Features | Docs |
|----------|----------|-------|--------------|------|
| Hostinger | Small-medium sites | $ | Easy management, good value | [HOSTINGER.md](HOSTINGER.md) |
| Hetzner Cloud | Production apps | $$ | Excellent performance, API | [HETZNER.md](HETZNER.md) |
| Closte | VPS hosting | $$ | Competitive pricing, flexibility | [CLOSTE.md](CLOSTE.md) |

### Deployment Platforms

| Platform | Best For | Complexity | Key Features | Docs |
|----------|----------|------------|--------------|------|
| Coolify | Self-hosted PaaS | Medium | Docker-based, full control | [COOLIFY.md](COOLIFY.md) |
| Cloudron | App management | Low | One-click apps, easy management | [CLOUDRON.md](CLOUDRON.md) |

### DNS & Domain Management

| Provider | Best For | API Quality | Key Features | Docs |
|----------|----------|-------------|--------------|------|
| Cloudflare | Global performance | Excellent | CDN, security, analytics | [CLOUDFLARE-SETUP.md](CLOUDFLARE-SETUP.md) |
| Spaceship | Modern domain mgmt | Excellent | Developer-friendly, competitive pricing | [SPACESHIP.md](SPACESHIP.md) |
| 101domains | Large portfolios | Excellent | Extensive TLDs, privacy features | [101DOMAINS.md](101DOMAINS.md) |
| Route 53 | AWS integration | Excellent | Advanced routing, health checks | [route53-dns-config.json.txt](../configs/route53-dns-config.json.txt) |
| Namecheap | Domain registration | Limited | Affordable, basic DNS | [namecheap-dns-config.json.txt](../configs/namecheap-dns-config.json.txt) |

### Other Services

| Service | Purpose | Docs |
|---------|---------|------|
| Amazon SES | Scalable email delivery with analytics | [SES.md](SES.md) |
| MainWP | Self-hosted WordPress management | [MAINWP.md](MAINWP.md) |
| Vaultwarden | Self-hosted password/secrets management | [VAULTWARDEN.md](VAULTWARDEN.md) |
| Code Auditing | Multi-platform code quality & security | [CODE-AUDITING.md](CODE-AUDITING.md) |
| Git Platforms | GitHub, GitLab, Gitea, local Git | [GIT-PLATFORMS.md](GIT-PLATFORMS.md) |
| Domain Purchasing | Automated domain purchasing | [DOMAIN-PURCHASING.md](DOMAIN-PURCHASING.md) |

### Local Development

| Tool | Purpose | Docs |
|------|---------|------|
| LocalWP | Local WordPress dev with MCP integration | [LOCALWP-MCP.md](LOCALWP-MCP.md) |
| Localhost | `.local` domains, SSL, port management | [LOCALHOST.md](LOCALHOST.md) |
| Context7 MCP | Real-time documentation for AI assistants | [CONTEXT7-MCP-SETUP.md](CONTEXT7-MCP-SETUP.md) |
| MCP Servers | Model Context Protocol configuration | [MCP-SERVERS.md](MCP-SERVERS.md) |
| Crawl4AI | AI-powered web crawler, LLM-friendly output | [CRAWL4AI.md](CRAWL4AI.md) |

## Infrastructure Organization

### Multi-Project Architecture

- **Separate API tokens** per project/client
- **Descriptive naming**: Clear project names (main, client-project, storagebox)
- **Account isolation**: Separate production, development, and client environments
- **Documentation**: Maintain descriptions for each project/account

### Hetzner Account Structure Example

```json
{
  "accounts": {
    "main": { "api_token": "YOUR_MAIN_TOKEN", "description": "Main production account" },
    "client-project": { "api_token": "YOUR_CLIENT_PROJECT_TOKEN", "description": "Client project account" },
    "storagebox": { "api_token": "YOUR_STORAGE_TOKEN", "description": "Storage and backup account" }
  }
}
```

### Hostinger Multi-Site Management

- **Domain-based organization**: Group sites by domain/purpose
- **Consistent paths**: Standard `/domains/[domain]/public_html` structure
- **Password management**: Separate password files per server group
- **Site categorization**: Group by client, project type, or environment

## Security Best Practices

### API Token Management

- Store in `~/.config/aidevops/` (user-private, 600 perms) -- never in repo
- Different tokens for prod/dev/staging
- Rotate quarterly, use least-privilege permissions
- Always add config files to `.gitignore`

### SSH Key Standardization

- Use Ed25519 keys (faster, more secure than RSA)
- Standardize keys across all servers with passphrase protection
- Audit and remove unused keys regularly

### Password Authentication (Hostinger/Closte)

- Store passwords in separate files with 600 permissions (e.g., `hostinger_password`, `closte_web_password`)
- Use `sshpass` for automated password authentication
- Add password files to `.gitignore`

## Domain & SSL Management

### Local Development

- `.local` suffix for all local domains; SSL certificates by default
- Port ranges: WordPress 10000-10999, APIs 8000-8999, MCP 8080+, databases standard (5432/3306/6379)
- Setup `dnsmasq` for automatic `.local` resolution

### LocalWP Integration

```bash
# List LocalWP sites
./.agents/scripts/localhost-helper.sh list-localwp

# Setup custom domain for LocalWP site
./.agents/scripts/localhost-helper.sh setup-localwp-domain plugin-testing plugin-testing.local

# Generate SSL certificate
./.agents/scripts/localhost-helper.sh generate-cert plugin-testing.local
```

Map LocalWP ports to custom `.local` domains. Use Traefik reverse proxy for clean domain access.

### Production SSL

- Let's Encrypt with automated renewal
- Wildcard certificates for multi-subdomain setups
- Monitor expiration dates

## Development Environment

### Docker

- Shared networks for all local containers
- Standardize Traefik labels and volume naming
- Use `.env` files for configuration

### MCP Port Allocation

```json
{
  "mcp_integration": {
    "base_port": 8081,
    "port_allocation": {
      "hostinger": 8080,
      "hetzner-main": 8081,
      "hetzner-client-project": 8082,
      "hetzner-storagebox": 8083,
      "closte": 8084
    }
  }
}
```

Sequential allocation from base port. Use descriptive names matching account structure. Monitor MCP server health.

## Monitoring & Maintenance

| Cadence | Tasks |
|---------|-------|
| Weekly | Server status, resource usage |
| Monthly | API token rotation review |
| Quarterly | SSH key audit, access permissions |
| Annually | Security practices review |

Automate: health checks, backup verification, SSL expiration alerts, resource monitoring (CPU/memory/disk).
