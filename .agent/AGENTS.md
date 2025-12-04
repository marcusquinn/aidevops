# AI DevOps Framework - User Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: DevOps automation across multiple services
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Configs**: `configs/[service]-config.json` (gitignored, use `.json.txt` templates)
- **Credentials**: `~/.config/aidevops/mcp-env.sh` (600 permissions)

**Critical Rules**:
- NEVER create files in `~/` root - use `~/.aidevops/.agent-workspace/work/[project]/`
- NEVER expose credentials in output/logs
- Confirm destructive operations before execution
- Store secrets ONLY in `~/.config/aidevops/mcp-env.sh`

**Quality Standards**: SonarCloud A-grade, ShellCheck zero violations

## Main Agents

| Agent | Purpose |
|-------|---------|
| `plan-plus.md` | Read-only planning with semantic codebase search |
| `build-plus.md` | Enhanced Build with context tools |
| `aidevops.md` | Framework operations, meta-agents, setup |
| `wordpress.md` | WordPress ecosystem management |
| `seo.md` | SEO optimization and analysis |
| `content.md` | Content creation workflows |
| `research.md` | Research and analysis tasks |
| `marketing.md` | Marketing strategy |
| `sales.md` | Sales operations |
| `legal.md` | Legal compliance |
| `accounting.md` | Financial operations |
| `health.md` | Health and wellness |

## Subagent Folders

| Folder | Contents |
|--------|----------|
| `aidevops/` | Framework meta-agents (agent-designer, add-new-mcp, setup, troubleshooting) |
| `wordpress/` | WordPress subagents (wp-dev, wp-admin, localwp, mainwp) |
| `seo/` | SEO subagents (google-search-console) |
| `content/` | Content subagents (guidelines) |
| `tools/git/` | Git platform CLIs (github, gitlab, gitea, workflow) |
| `tools/code-review/` | Quality tools (sonarcloud, codacy, coderabbit, snyk, secretlint) |
| `tools/browser/` | Browser automation (playwright, chrome-devtools, crawl4ai) |
| `tools/context/` | Context tools (augment-context-engine, context-builder, context7, toon, dspy) |
| `tools/credentials/` | Credential management (vaultwarden, api-keys) |
| `tools/deployment/` | Deployment tools (coolify, vercel) |
| `tools/opencode/` | OpenCode configuration and paths |
| `services/hosting/` | Hosting providers (hostinger, hetzner, cloudflare, dns) |
| `services/email/` | Email services (ses) |
| `services/accounting/` | Accounting services (quickfile) |
| `workflows/` | Process guides (release, bug-fixing, versioning) |

<!-- AI-CONTEXT-END -->

## Getting Started

Run `setup.sh` from the aidevops repository to install agents locally:

```bash
cd ~/Git/aidevops
./setup.sh
```

This copies agents to `~/.aidevops/agents/` and configures AI assistants.

For AI-assisted setup guidance, see `aidevops/setup.md`.

## Progressive Disclosure

Read subagents only when task requires them. The AI-CONTEXT section above contains essential information for most tasks.

**When to read more:**
- Specific service operations → `services/hosting/[provider].md`
- Code quality tasks → `tools/code-review/`
- WordPress work → `wordpress/`
- Release/versioning → `workflows/`

## Security

- All credentials in `~/.config/aidevops/mcp-env.sh` (600 permissions)
- Configuration templates in `configs/*.json.txt` (committed)
- Working configs in `configs/*.json` (gitignored)
- Confirm destructive operations before execution

## Working Directories

```text
~/.aidevops/.agent-workspace/
├── work/[project]/    # Persistent project files
├── tmp/session-*/     # Temporary session files (cleanup)
└── memory/            # Cross-session patterns and preferences
```

Never create files in `~/` root.

## Development Workflows

For versioning, releases, and git operations:

| Task | Subagent |
|------|----------|
| Version bumps | `workflows/versioning.md` |
| Creating releases | `workflows/release-process.md` |
| Git branching | `tools/git/workflow.md` |
| Bug fixes | `workflows/bug-fixing.md` |
| Feature development | `workflows/feature-development.md` |

**Quick commands:**

```bash
# Version bump and release
.agent/scripts/version-manager.sh release [major|minor|patch]

# Quality check before commit
.agent/scripts/quality-check.sh
```
