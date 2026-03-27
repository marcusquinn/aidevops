---
description: Documentation AI context and guidelines
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
---

# Documentation AI Context

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Location**: `.agents/*.md` (lowercase filenames)
- **Service guides**: hostinger.md, hetzner.md, coolify.md, mainwp.md, etc.
- **Structure**: Overview, Configuration, Usage, Security, Troubleshooting, MCP Integration
- **AI Context blocks**: `<!-- AI-CONTEXT-START -->` for quick reference
- **Cross-service workflows**: Domain -> DNS -> Hosting, Dev -> Quality -> Deploy
- **Best practices**: recommendations-opinionated.md for provider selection
- **Setup guides**: *-setup.md for complex integrations
- **Config templates**: `configs/[service]-config.json.txt`
- **Discovery**: Use `git ls-files '.agents/*.md'` — not hardcoded lists

<!-- AI-CONTEXT-END -->

## Service Guides

Discover with `git ls-files '.agents/*.md'`. Key categories:

| Category | Guides |
|----------|--------|
| Infrastructure & Hosting | hostinger.md, hetzner.md, closte.md, cloudron.md |
| Deployment & Content | coolify.md, mainwp.md |
| Security & Quality | vaultwarden.md, code-auditing.md |
| Version Control & Domains | git-platforms.md, domain-purchasing.md, spaceship.md, 101domains.md |
| Email & DNS | ses.md, dns-providers.md |
| Development & Local | localhost.md, localwp-mcp.md, mcp-servers.md, context7-mcp-setup.md |
| Framework | recommendations-opinionated.md, cloudflare-setup.md, coolify-setup.md |

## Standard Guide Structure

Each service guide follows this format:

```markdown
# [Service Name] Guide

## Provider Overview
- Service type, strengths, API support, use cases

## Configuration
## Usage Examples
## Security Best Practices
## Troubleshooting
## MCP Integration (if applicable)
## Best Practices
## AI Assistant Integration
```

## Documentation Standards

**Content**: Complete feature coverage, real working examples, security considerations, troubleshooting, AI integration patterns.

**Writing**: Clear technical language, consistent formatting, syntax-highlighted code, visual hierarchy with headers, cross-references to related guides.

**Technical**: Accurate command syntax, current API info, working sanitized config examples, version-aware where applicable.

## Maintenance

- Update on service API changes, new features, security advisories
- Verify all commands and examples work
- Keep structure consistent across guides
- Evolve best practices from experience

## Cross-Service Workflows

Common integration patterns:

**Domain -> DNS -> Hosting:**
- Domain purchasing (Spaceship/101domains) -> DNS (Cloudflare/Route53) -> Hosting (Hetzner/Hostinger)

**Development -> Quality -> Deployment:**
- Git platforms (GitHub/GitLab) -> Code auditing (CodeRabbit/SonarCloud) -> Deployment (Coolify/hosting)

**Security -> Credentials -> Monitoring:**
- Vaultwarden (credentials) -> Email monitoring (SES) -> Security auditing

Each service guide includes integration examples, workflow patterns, cross-service dependencies, and combined operation examples.

## Finding Information

```bash
# Service-specific information
.agents/[service-name].md

# Framework overview
.agents/AGENTS.md

# Provider selection guidance
.agents/recommendations.md

# Setup procedures
.agents/[service]-setup.md
```

**Navigation priority**: Service guide (primary) -> Framework context (AGENTS.md) -> Best practices guide -> Setup guides -> Context7 MCP (latest external docs).
