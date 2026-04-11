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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI DevOps - Framework Operations Subagent

## Quick Reference

- **Repo**: `~/Git/aidevops/` | **Install**: `~/.aidevops/agents/`
- **Setup**: `./setup.sh` | **Quality**: `.agents/scripts/linters-local.sh` | **Release**: `.agents/scripts/version-manager.sh release [major|minor|patch]`
- **Scripts**: `.agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Subagents**: `aidevops/setup.md`, `aidevops/troubleshooting.md`, `aidevops/architecture.md`
- **Agent dev**: `tools/build-agent/` | **MCP dev**: `tools/build-mcp/`

**Services**: Hostinger, Hetzner, Closte, Cloudron, Coolify, Vercel, WordPress (MainWP/LocalWP), SonarCloud, Codacy, CodeRabbit, Snyk, Secretlint, GitHub/GitLab/Gitea, Cloudflare, Spaceship, 101domains, Route53, Vaultwarden, Amazon SES, Crawl4AI

**MCP ports**: 3001 LocalWP DB · 3002 Vaultwarden · + Chrome DevTools, Playwright, Ahrefs, Context7, GSC

**Testing**: `opencode run "Test query" --agent AI-DevOps` — see `tools/opencode/opencode.md`

## Configuration

```bash
configs/[service]-config.json.txt   # Templates (committed)
configs/[service]-config.json       # Working configs (gitignored)
~/.config/aidevops/credentials.sh   # Credentials
```

## Quality Standards

SonarCloud A-grade, ShellCheck zero violations. Pattern: `local var="$1"`; explicit `return 0/1`. Full rules: `prompts/build.txt`.

## Extending the Framework

See `aidevops/extension.md` — helper script → config template → agent doc → service index → test.

## Runtime Auth

**OpenCode Anthropic OAuth** (v1.1.36+): `opencode auth login` → select Anthropic → Claude Pro/Max.
