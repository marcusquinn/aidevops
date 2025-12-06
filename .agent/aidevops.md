# AI DevOps - Framework Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Manage and extend the aidevops framework
- **Repo**: `~/Git/aidevops/`
- **User Install**: `~/.aidevops/agents/`
- **Scripts**: `.agent/scripts/[service]-helper.sh [command] [account] [target]`

**Key Operations**:
- Setup: `./setup.sh`
- Quality check: `.agent/scripts/linters-local.sh`
- Release: `.agent/scripts/version-manager.sh release [major|minor|patch]`

**Subagents** (`aidevops/`):
- `setup.md` - AI guide to setup.sh
- `troubleshooting.md` - Service status, debugging
- `architecture.md` - Framework structure

**Related Main Agents**:
- `Build-Agent` - Composing efficient agents (see `build-agent.md`)

**Services**: Hostinger, Hetzner, Cloudflare, GitHub/GitLab/Gitea, MainWP,
Vaultwarden, SonarCloud, Codacy, CodeRabbit, Snyk, Crawl4AI, MCP integrations

<!-- AI-CONTEXT-END -->

## Framework Overview

AI DevOps provides comprehensive infrastructure management for AI agents:

- **Infrastructure**: Hostinger, Hetzner, Closte, Cloudron
- **Deployment**: Coolify, Vercel
- **Content**: WordPress (MainWP, LocalWP)
- **Quality**: SonarCloud, Codacy, CodeRabbit, Snyk, Secretlint
- **Git**: GitHub, GitLab, Gitea with CLI integrations
- **DNS/Domains**: Cloudflare, Spaceship, 101domains, Route53
- **Security**: Vaultwarden, credential management
- **Email**: Amazon SES

## Command Pattern

All services follow unified patterns:

```bash
.agent/scripts/[service]-helper.sh [command] [account] [target] [options]

# Common commands
help                    # Show service-specific help
accounts|instances      # List configured accounts
monitor|audit|status    # Service monitoring
```

## Configuration

```bash
# Templates (committed)
configs/[service]-config.json.txt

# Working configs (gitignored)
configs/[service]-config.json

# Credentials
~/.config/aidevops/mcp-env.sh
```

## Quality Standards

- SonarCloud: A-grade (zero vulnerabilities, bugs)
- ShellCheck: Zero violations
- Pattern: `local var="$1"` not `$1` directly
- Explicit `return 0/1` in all functions

## Extending the Framework

See `aidevops/extension.md` for adding new services:

1. Create helper script following existing patterns
2. Add config template
3. Create agent documentation
4. Update service index
5. Test thoroughly

## MCP Integrations

```
Port 3001: LocalWP WordPress database
Port 3002: Vaultwarden credentials
+ Chrome DevTools, Playwright, Ahrefs, Context7, GSC MCPs
```
