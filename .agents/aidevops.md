---
name: aidevops
description: Framework operations subagent - use @aidevops for setup, configuration, troubleshooting (Build+ is the primary agent)
mode: subagent
subagents:
  # Framework internals
  - setup
  - troubleshooting
  - architecture
  - add-new-mcp-to-aidevops
  - mcp-integrations
  - mcp-troubleshooting
  - configs
  - providers
  # Agent development
  - build-agent
  - agent-review
  - build-mcp
  - server-patterns
  - api-wrapper
  - transports
  - deployment
  # Workflows
  - git-workflow
  - release
  - version-bump
  - preflight
  - postflight
  # Code quality
  - code-standards
  - linters-local
  - secretlint
  # Credentials
  - api-key-setup
  - api-key-management
  - vaultwarden
  - list-keys
  # Built-in
  - general
  - explore
---

# AI DevOps - Framework Operations Subagent

> **Note**: AI-DevOps is now a subagent, not a primary agent. Use `@aidevops` when you need
> framework-specific operations (setup, troubleshooting, architecture). Build+ is the primary
> unified coding agent.

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

**Related Subagents** (in `tools/`):
- `tools/build-agent/` - Agent design and composition
- `tools/build-mcp/` - MCP server development

**Services**: Hostinger, Hetzner, Cloudflare, GitHub/GitLab/Gitea, MainWP,
Vaultwarden, SonarCloud, Codacy, CodeRabbit, Snyk, Crawl4AI, MCP integrations

**Testing**: Use OpenCode CLI to test config changes without restarting TUI:

```bash
opencode run "Test query" --agent AI-DevOps
```text

See `tools/opencode/opencode.md` for CLI testing patterns.

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
```text

## Configuration

```bash
# Templates (committed)
configs/[service]-config.json.txt

# Working configs (gitignored)
configs/[service]-config.json

# Credentials
~/.config/aidevops/mcp-env.sh
```text

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

```text
Port 3001: LocalWP WordPress database
Port 3002: Vaultwarden credentials
+ Chrome DevTools, Playwright, Ahrefs, Context7, GSC MCPs
```text

## OpenCode Plugins

**Antigravity OAuth** (`opencode-antigravity-auth`): Enables Google OAuth for OpenCode,
providing access to Antigravity rate limits and premium models.

```bash
# Authenticate after setup
opencode auth login
# Select: Google → OAuth with Google (Antigravity)
```text

**Available models**: gemini-3-pro-high, claude-opus-4-5-thinking, claude-sonnet-4-5-thinking

**Multi-account**: Add multiple Google accounts for load balancing and failover.

See: https://github.com/NoeFabris/opencode-antigravity-auth
