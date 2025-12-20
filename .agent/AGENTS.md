# AI DevOps Framework - User Guide

**New to aidevops?** Type `/onboarding` to get started with an interactive setup wizard.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: DevOps automation across multiple services
- **Getting Started**: `/onboarding` - Interactive setup wizard for new users
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Configs**: `configs/[service]-config.json` (gitignored, use `.json.txt` templates)
- **Credentials**: `~/.config/aidevops/mcp-env.sh` (600 permissions)

**Critical Rules**:
- NEVER create files in `~/` root - use `~/.aidevops/.agent-workspace/work/[project]/` for files needed only with the current task.
- NEVER expose credentials in output/logs
- Confirm destructive operations before execution
- Store secrets ONLY in `~/.config/aidevops/mcp-env.sh`

**Quality Standards**: SonarCloud A-grade, ShellCheck zero violations

**SonarCloud Hotspot Patterns** (auto-excluded via `sonar-project.properties`):
- Scripts matching `*-helper.sh`, `*-setup.sh`, `*-cli.sh`, `*-verify.sh` are excluded from:
  - S5332 (clear-text protocol) - `http://localhost` for local dev
  - S6506 (HTTPS not enforced) - `curl|bash` for official installers
- Add `# SONAR:` comments for documentation, exclusions handle suppression

## Planning Workflow

**After completing planning/research in a conversation**, offer the user a choice:

> We've planned [summary]. How would you like to proceed?
>
> 1. **Execute now** - Start implementation immediately
> 2. **Add to TODO.md** - Record as quick task for later
> 3. **Create execution plan** - Add to `todo/PLANS.md` with full PRD/tasks
>
> Which option? (1-3)

| Scope | Time Estimate | Recommendation |
|-------|---------------|----------------|
| Trivial | < 30 mins | Execute now |
| Small | 30 mins - 2 hours | TODO.md |
| Medium | 2 hours - 1 day | TODO.md + notes |
| Large | 1+ days | todo/PLANS.md |
| Complex | Multi-session | todo/PLANS.md + PRD + tasks |

**Planning files:**

| File | Purpose |
|------|---------|
| `TODO.md` | Quick tasks, backlog (root level) |
| `todo/PLANS.md` | Complex execution plans |
| `todo/tasks/prd-*.md` | Product requirement documents |
| `todo/tasks/tasks-*.md` | Implementation task lists |

**Slash commands:** `/create-prd`, `/generate-tasks`, `/plan-status`, `/log-time-spent`

**Time tracking format:**

```markdown
- [ ] Task description @owner #tag ~4h (ai:2h test:1h) started:2025-01-15T10:30Z
```

| Field | Purpose | Example |
|-------|---------|---------|
| `~estimate` | Total time estimate | `~4h`, `~30m`, `~2h30m` |
| `(breakdown)` | AI/test/read time | `(ai:2h test:1h read:30m)` |
| `started:` | Branch creation time | `started:2025-01-15T10:30Z` |
| `completed:` | Task completion time | `completed:2025-01-16T14:00Z` |
| `actual:` | Actual time spent | `actual:5h30m` |
| `logged:` | Cumulative logged time | `logged:3h` |

**Configure per-repo:** `.aidevops.json` with `"time_tracking": true|false|"prompt"`

**Full workflow:** See `workflows/plans.md` (full) or `workflows/plans-quick.md` (quick)

## Git Workflow (File Changes)

**When conversation indicates file creation/modification in a git repo**:

1. Check current branch: `git branch --show-current`
2. Check `TODO.md` and `todo/PLANS.md` for matching tasks
3. Check for existing branches that might match the task
4. If on `main`: Present numbered options (tasks from TODO.md, existing branches, create new, or continue on main)
5. Derive branch name from task/plan when available
6. Read `workflows/git-workflow.md` for full workflow guidance

**Branch types**: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

**User prompts**: Always offer numbered options. User can reply with number or "yes" for default.

**Issue URLs**: Paste any GitHub/GitLab/Gitea issue URL to auto-setup branch.

**After completing file changes**, offer numbered options:

1. Run preflight checks (`workflows/preflight.md`)
2. Skip preflight and commit directly (not recommended)
3. Continue making more changes

Only offer to commit after preflight passes or user explicitly skips.

**Testing Config Changes**: Use CLI to test without TUI restart:

```bash
~/.aidevops/agents/scripts/opencode-test-helper.sh test-mcp <name> <agent>
```

**MCP Setup Validation** (MANDATORY after config changes):

```bash
# 1. Verify MCP status
opencode mcp list

# 2. If "Connection closed" - diagnose
~/.aidevops/agents/scripts/mcp-diagnose.sh <name>

# 3. Check for version updates
~/.aidevops/agents/scripts/tool-version-check.sh
```

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
| `aidevops/` | Framework meta-agents (onboarding, add-new-mcp, setup, troubleshooting, architecture, security) |
| `build-agent/` | Agent design subagents (agent-review) |
| `build-mcp/` | MCP development (api-wrapper, deployment, server-patterns, transports) |
| `memory/` | Cross-session memory patterns |
| `wordpress/` | WordPress subagents (wp-dev, wp-admin, localwp, mainwp, wp-preferred) |
| `seo/` | SEO subagents (keyword-research, google-search-console, dataforseo, serper, site-crawler, eeat-score, domain-research) |
| `content/` | Content subagents (guidelines) |
| `tools/ai-assistants/` | AI tools (agno, capsolver, windsurf, configuration) |
| `tools/browser/` | Browser automation (dev-browser, playwriter, playwright, stagehand, crawl4ai, pagespeed) |
| `tools/ui/` | UI component libraries (shadcn) |
| `tools/code-review/` | Quality tools (code-standards, codacy, coderabbit, qlty, snyk, auditing, automation) |
| `tools/context/` | Context tools (osgrep, augment-context-engine, context-builder, context7, toon, dspy, dspyground) |
| `tools/conversion/` | Format conversion (pandoc) |
| `tools/data-extraction/` | Data extraction (outscraper) |
| `tools/deployment/` | Deployment tools (coolify, coolify-cli, coolify-setup, vercel) |
| `tools/git/` | Git platforms (github-cli, gitlab-cli, gitea-cli, github-actions, authentication, security) |
| `tools/credentials/` | Credential management (list-keys, api-key-management, api-key-setup, vaultwarden) |
| `tools/opencode/` | OpenCode configuration, paths, oh-my-opencode integration |
| `services/hosting/` | Hosting providers (hostinger, hetzner, cloudflare, cloudron, closte, 101domains, spaceship, localhost, dns-providers, domain-purchasing) |
| `services/email/` | Email services (ses) |
| `services/accounting/` | Accounting services (quickfile) |
| `workflows/` | Process guides (git-workflow, branch, plans, plans-quick, release, version-bump, bug-fixing, feature-development, pr, code-audit-remote, error-feedback, multi-repo-workspace) |
| `templates/` | PRD and task templates (prd-template, tasks-template) |
| `workflows/branch/` | Branch type workflows (feature, bugfix, hotfix, refactor, chore, experiment, release) |

<!-- AI-CONTEXT-END -->

## Getting Started

Run `setup.sh` from the aidevops repository to install agents locally:

```bash
cd ~/Git/aidevops
./setup.sh
```

This copies agents to `~/.aidevops/agents/` and configures AI assistants.

**Initialize aidevops in any project:**

```bash
aidevops init                    # Enable all features
aidevops init planning           # Enable only planning
aidevops init planning,git-workflow  # Enable multiple features
aidevops features                # List available features
```

**CLI commands:**

| Command | Purpose |
|---------|---------|
| `aidevops init [features]` | Initialize aidevops in current project |
| `aidevops features` | List available features |
| `aidevops status` | Check installation status |
| `aidevops update` | Update to latest version |
| `aidevops uninstall` | Remove aidevops |

For AI-assisted setup guidance, see `aidevops/setup.md`.

## Progressive Disclosure

Read subagents only when task requires them. The AI-CONTEXT section above contains essential information for most tasks.

**When to read more:**
- Planning complex work → `workflows/plans.md` or `workflows/plans-quick.md`
- Specific service operations → `services/[type]/[provider].md`
- Code quality tasks → `tools/code-review/`
- WordPress work → `wordpress/`
- Release/versioning → `workflows/`
- Browser automation → `tools/browser/`
- MCP development → `build-mcp/`
- SEO analysis → `seo/` (keyword-research, google-search-console, dataforseo, serper, site-crawler, eeat-score, domain-research)
- Database migrations → `workflows/sql-migrations.md`
- Oh-My-OpenCode integration → `tools/opencode/oh-my-opencode.md` (LSP, AST, background agents)
- Working in `~/Git/aidevops/` → `aidevops/architecture.md` (framework internals)

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
| `list-keys-helper.sh` | List all API keys with their storage locations |
| `linters-local.sh` | Run local linting (ShellCheck, secretlint, patterns) |
| `code-audit-helper.sh` | Run remote auditing (CodeRabbit, Codacy, SonarCloud) |
| `version-manager.sh` | Version bumps and releases |
| `linter-manager.sh` | Install and manage linters |
| `github-cli-helper.sh` | GitHub operations |
| `coolify-helper.sh` | Coolify deployment management |
| `stagehand-helper.sh` | Browser automation with Stagehand |
| `crawl4ai-helper.sh` | Web crawling and extraction |
| `domain-research-helper.sh` | DNS intelligence (rDNS, subdomains, CNAMEs) |
| `toon-helper.sh` | TOON format conversion |
| `sonarcloud-cli.sh` | SonarCloud analysis |
| `codacy-cli.sh` | Codacy code quality |
| `secretlint-helper.sh` | Secret detection |
| `opencode-test-helper.sh` | Test OpenCode config changes via CLI |

## Quality Workflow

```text
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
| **Windsurf** | Point to `~/.aidevops/agents/AGENTS.md` or create local `.windsurfrules` |
| **Codex** | Point to `~/.aidevops/agents/` |
| **Factory** | Point to `~/.aidevops/agents/` |
| **Continue** | Configure to read `~/.aidevops/agents/` |
| **Kiro** | Configure to read `~/.aidevops/agents/` |
| **Other tools** | Point to `~/.aidevops/agents/AGENTS.md` |

**Note**: Tool-specific files and directories (`.cursorrules`, `.windsurfrules`, `.continuerules`, `.cursor/`, `.claude/`, `.codex/`, `.factory/`, `.ai`, `.kiro`, `.continue`) are not tracked in git as they cause duplicate `@` references in OpenCode. Create symlinks locally if needed, or configure tools to read from `~/.aidevops/agents/`.

## Development Workflows

For versioning, releases, and git operations:

| Task | Subagent |
|------|----------|
| Planning (full) | `workflows/plans.md` |
| Planning (quick) | `workflows/plans-quick.md` |
| Version bumps | `workflows/version-bump.md` |
| Creating releases | `workflows/release.md` |
| Git branching | `workflows/git-workflow.md` |
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
