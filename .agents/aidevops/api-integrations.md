---
description: Comprehensive API integration guide
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

# API Integration Guide

<!-- AI-CONTEXT-START -->

**Total APIs**: 28+ integrated services

**Pattern**: `configs/[service]-config.json` + `.agents/scripts/[service]-helper.sh`

```bash
# Setup
bash .agents/scripts/setup-local-api-keys.sh set [service]-api-key YOUR_KEY
bash .agents/scripts/setup-local-api-keys.sh list
bash .agents/scripts/test-all-apis.sh
```

<!-- AI-CONTEXT-END -->

## Service Catalog

### Infrastructure & Hosting

| Service | Auth | Config | Helper | Notes |
|---------|------|--------|--------|-------|
| Hostinger | API Token | `configs/hostinger-config.json` | `hostinger-helper.sh` | VPS, domains, hosting plans |
| Hetzner Cloud | API Token | `configs/hetzner-config.json` | `hetzner-helper.sh` | Servers, networking, snapshots, load balancers |
| Closte | API Key | `configs/closte-config.json` | `closte-helper.sh` | Managed hosting, app deployment |
| Coolify | API Token | `configs/coolify-config.json` | `coolify-helper.sh` | Self-hosted PaaS, Docker, service management |

### Domain & DNS

| Service | Auth | Config | Helper | Notes |
|---------|------|--------|--------|-------|
| Cloudflare | API Token (scoped) | `configs/cloudflare-dns-config.json` | `dns-helper.sh` | DNS, security rules, analytics, caching |
| Spaceship | API Key | `configs/spaceship-config.json` | `spaceship-helper.sh` | Registration, WHOIS, transfers |
| 101domains | API Credentials | `configs/101domains-config.json` | `101domains-helper.sh` | Bulk operations, pricing, availability |
| AWS Route 53 | AWS Access Keys | `configs/route53-dns-config.json` | `dns-helper.sh` | DNS hosting, health checks, traffic routing |
| Namecheap | API Key + Username | `configs/namecheap-dns-config.json` | `dns-helper.sh` | Domain management, DNS, SSL certificates |

### Communication

| Service | Auth | Config | Helper | Notes |
|---------|------|--------|--------|-------|
| Amazon SES | AWS Access Keys | `configs/ses-config.json` | `ses-helper.sh` | Email delivery, bounce tracking, reputation |
| Twilio | Account SID + Auth Token | `configs/twilio-config.json` | `twilio-helper.sh` | SMS/MMS, voice, WhatsApp Business, Verify (2FA), Lookup, recordings. AUP compliance required. Telfon app for end-user UI (https://mytelfon.com/) |
| MainWP | API Key | `configs/mainwp-config.json` | `mainwp-helper.sh` | WordPress site management, updates, backups |

### Security & Code Quality

| Service | Auth | Config/Setup | Notes |
|---------|------|--------------|-------|
| Vaultwarden | API Token | `configs/vaultwarden-config.json` / `vaultwarden-helper.sh` | Credential storage, secure sharing, audit logs |
| CodeRabbit | API Key | `coderabbit-cli.sh` | AI code review, security scanning |
| Codacy | API Token | `codacy-cli.sh` | Quality metrics, coverage tracking |
| SonarCloud | API Token | GitHub Actions workflow | Security hotspots, code smells, coverage |
| CodeFactor | GitHub integration | Automatic via GitHub | Quality scoring, trend analysis |

### SEO & Analytics

| Service | Auth | Integration | Notes |
|---------|------|-------------|-------|
| Ahrefs | API Key | `mcp-server-ahrefs` | Backlink analysis, keyword research, competitor analysis |
| Google Search Console | Service Account (GCP) | `mcp-server-gsc` | Search analytics, Core Web Vitals, index coverage |
| Perplexity | API Key | `perplexity-mcp` | Research queries, content generation, fact-checking |

### Git Platforms

All three share `git-platforms-helper.sh`.

| Service | Auth | Notes |
|---------|------|-------|
| GitHub | Personal Access Token | Repos, Actions, security scanning |
| GitLab | Personal Access Token | Projects, CI/CD pipelines, security features |
| Gitea | API Token | Self-hosted repos, user admin, webhooks |

### Development Tools

| Service | Auth | Integration | Notes |
|---------|------|-------------|-------|
| Context7 | API Key | `@context7/mcp-server` | Real-time library docs, code examples, API references |
| LocalWP | Local access | Custom MCP server | WordPress DB queries, site management, dev tools |
| Pandoc | None (local) | `pandoc-helper.sh` | Multi-format → markdown conversion (Word, PDF, HTML, EPUB, LaTeX, 20+ formats) |
| Agno AgentOS | LLM provider keys | `agno-setup.sh` | Multi-agent framework, production runtime, Agent-UI web interface |
| Playwright/Selenium | Site credentials (local only) | Included in `agno-setup.sh` | Local browser automation — LinkedIn, web scraping, form filling. No cloud services. |

## Setup

```bash
# Full setup
bash setup.sh

# Single service
cp configs/[service]-config.json.txt configs/[service]-config.json
# Edit with credentials, then:
./.agents/scripts/[service]-helper.sh test-connection
```

## References

- [MCP Integration Guide](MCP-INTEGRATIONS.md)
- [Security Best Practices](.agents/aidevops/security.md)
- [Configuration Templates](../configs/)
- [Helper Scripts](../.agents/scripts/)
