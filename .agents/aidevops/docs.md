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
- **Discovery**: `git ls-files '.agents/*.md'` — never hardcode guide lists
- **Guide shape**: Overview → Configuration → Usage → Security → Troubleshooting → MCP/AI integration
- **Quick-load block**: `<!-- AI-CONTEXT-START -->` for stable high-signal context
- **Config templates**: `configs/[service]-config.json.txt`
- **Setup docs**: `*-setup.md` for multi-step integrations
- **Provider guidance**: `recommendations-opinionated.md`
- **Cross-service flows**: Domain → DNS → Hosting; Dev → Quality → Deploy

<!-- AI-CONTEXT-END -->

## Service Guide Categories

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

- `# [Service Name] Guide`
- `## Provider Overview` — service type, strengths, API support, use cases
- `## Configuration`
- `## Usage Examples`
- `## Security Best Practices`
- `## Troubleshooting`
- `## MCP Integration` / `## AI Assistant Integration` when relevant
- `## Best Practices`

## Standards & Maintenance

- Cover core features, working examples, security concerns, troubleshooting, and AI integration patterns
- Clear technical language, consistent formatting, syntax-highlighted code, cross-references
- Keep commands accurate, examples sanitized, API details current; version notes when they matter
- Update on API changes, new features, security advisories; keep structure consistent across guides

## Navigation

- Service-specific: `.agents/[service-name].md`
- Framework context: `.agents/AGENTS.md`
- Provider selection: `.agents/recommendations-opinionated.md`
- Setup procedures: `.agents/[service]-setup.md`

**Priority**: service guide → framework context → best-practices guide → setup guide → Context7 MCP for latest external docs.
