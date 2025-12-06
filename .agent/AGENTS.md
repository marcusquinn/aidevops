# AI DevOps Framework - User Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: DevOps automation across multiple services
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Configs**: `configs/[service]-config.json` (gitignored, use `.json.txt` templates)
- **Credentials**: `~/.config/aidevops/mcp-env.sh` (600 permissions)

**Critical Rules**:
- NEVER create files in `~/` root - use `~/.aidevops/.agent-workspace/work/[project]/` for files needed only with the current task.
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
| `build-agent.md` | Agent design and composition |
| `build-mcp.md` | MCP server development |
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
| `aidevops/` | Framework meta-agents (add-new-mcp, setup, troubleshooting, architecture, security) |
| `build-agent/` | Agent design subagents (agent-review) |
| `build-mcp/` | MCP development (api-wrapper, deployment, server-patterns, transports) |
| `memory/` | Cross-session memory patterns |
| `wordpress/` | WordPress subagents (wp-dev, wp-admin, localwp, mainwp, wp-preferred) |
| `seo/` | SEO subagents (google-search-console) |
| `content/` | Content subagents (guidelines) |
| `tools/ai-assistants/` | AI tools (agno, capsolver, windsurf, configuration) |
| `tools/browser/` | Browser automation (playwright, stagehand, stagehand-python, chrome-devtools, crawl4ai, pagespeed) |
| `tools/code-review/` | Quality tools (code-standards, codacy, coderabbit, qlty, snyk, auditing, automation) |
| `tools/context/` | Context tools (osgrep, augment-context-engine, context-builder, context7, toon, dspy, dspyground) |
| `tools/conversion/` | Format conversion (pandoc) |
| `tools/data-extraction/` | Data extraction (outscraper) |
| `tools/deployment/` | Deployment tools (coolify, coolify-cli, coolify-setup, vercel) |
| `tools/git/` | Git platforms (github-cli, gitlab-cli, gitea-cli, github-actions, authentication, security) |
| `tools/opencode/` | OpenCode configuration and paths |
| `services/hosting/` | Hosting providers (hostinger, hetzner, cloudflare, cloudron, closte, 101domains, spaceship, localhost, dns-providers, domain-purchasing) |
| `services/email/` | Email services (ses) |
| `services/accounting/` | Accounting services (quickfile) |
| `workflows/` | Process guides (branch, release, version-bump, bug-fixing, feature-development, pr, code-audit-remote, error-feedback, multi-repo-workspace) |
| `workflows/branch/` | Branch type workflows (feature, bugfix, hotfix, refactor, chore, experiment) |

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
- Specific service operations → `services/[type]/[provider].md`
- Code quality tasks → `tools/code-review/`
- WordPress work → `wordpress/`
- Release/versioning → `workflows/`
- Browser automation → `tools/browser/`
- MCP development → `build-mcp/`

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

Never create files in `~/` root for files needed only with the current task.

## Key Scripts

| Script | Purpose |
|--------|---------|
| `linters-local.sh` | Run local linting (ShellCheck, secretlint, patterns) |
| `code-audit-helper.sh` | Run remote auditing (CodeRabbit, Codacy, SonarCloud) |
| `version-manager.sh` | Version bumps and releases |
| `linter-manager.sh` | Install and manage linters |
| `github-cli-helper.sh` | GitHub operations |
| `coolify-helper.sh` | Coolify deployment management |
| `stagehand-helper.sh` | Browser automation with Stagehand |
| `crawl4ai-helper.sh` | Web crawling and extraction |
| `toon-helper.sh` | TOON format conversion |
| `sonarcloud-cli.sh` | SonarCloud analysis |
| `codacy-cli.sh` | Codacy code quality |
| `secretlint-helper.sh` | Secret detection |

## Quality Workflow

```
Development → @code-standards (reference)
     ↓
Pre-commit → /linters-local (fast, offline)
     ↓
PR Review → /pr (orchestrates all checks)
     ├── /linters-local
     ├── /code-audit-remote
     ├── /code-standards
     └── Intent vs Reality analysis
     ↓
Post-merge → /postflight (verify CI)
```

| Stage | Command | Purpose |
|-------|---------|---------|
| During development | `@code-standards` | Reference quality rules |
| Pre-commit | `/linters-local` | Fast local checks |
| PR creation | `/pr review` | Full orchestrated review |
| PR review | `/code-audit-remote` | Remote service audits |
| Post-merge | `/postflight` | Verify release health |

## AI Tool Configuration

The canonical agent location is `~/.aidevops/agents/` (deployed by `setup.sh`).

| Tool | Configuration |
|------|---------------|
| **OpenCode** | Agents in `~/.config/opencode/agent/`, generated by `generate-opencode-agents.sh` |
| **Claude Code** | Point to `~/.aidevops/agents/` or use `CLAUDE.md` symlink |
| **Cursor** | Configure rules path to `~/.aidevops/agents/` |
| **Windsurf** | Reads `.windsurfrules` symlink → `AGENTS.md` |
| **Codex** | Point to `~/.aidevops/agents/` |
| **Factory** | Point to `~/.aidevops/agents/` |
| **Continue** | Configure to read `~/.aidevops/agents/` |
| **Kiro** | Configure to read `~/.aidevops/agents/` |
| **Other tools** | Point to `~/.aidevops/agents/AGENTS.md` |

**Note**: Tool-specific directories (`.cursor/`, `.claude/`, `.codex/`, `.factory/`, `.ai`, `.kiro`, `.continue`) are not tracked in git as they cause duplicate `@` references in OpenCode. Create symlinks locally if needed for specific tools, or configure tools to read from `~/.aidevops/agents/`.

## Development Workflows

For versioning, releases, and git operations:

| Task | Subagent |
|------|----------|
| Version bumps | `workflows/version-bump.md` |
| Creating releases | `workflows/release.md` |
| Git branching | `tools/git/workflow.md` |
| Bug fixes | `workflows/bug-fixing.md` |
| Feature development | `workflows/feature-development.md` |
| PR review | `workflows/pr.md` |
| Remote auditing | `workflows/code-audit-remote.md` |
| Multi-repo work | `workflows/multi-repo-workspace.md` |

**Quick commands:**

```bash
# Version bump and release
.agent/scripts/version-manager.sh release [major|minor|patch]

# Local linting before commit
.agent/scripts/linters-local.sh

# Full PR review (orchestrates all checks)
/pr review
```
