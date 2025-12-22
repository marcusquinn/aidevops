---
mode: subagent
---
# AI DevOps Framework - User Guide

**New to aidevops?** Type `/onboarding` to get started with an interactive setup wizard.

## 🛑 MANDATORY: Pre-Edit Git Check

**BEFORE reading any file with intent to edit, or calling any edit/write tool:**

1. Run `git branch --show-current`
2. If on `main`, present this prompt and WAIT for user response:

> On `main`. Suggested branch: `{type}/{suggested-name}`
>
> 1. Create suggested branch (recommended)
> 2. Use different branch name
> 3. Stay on `main` (not recommended)

3. **Do NOT proceed until user replies with 1, 2, or 3**
4. After creating branch, call `session-rename_sync_branch` tool

**Why this matters**: Skipping this check causes direct commits to `main`, bypassing PR review.

---

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: DevOps automation across multiple services
- **Getting Started**: `/onboarding` - Interactive setup wizard for new users
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Configs**: `configs/[service]-config.json` (gitignored, use `.json.txt` templates)
- **Credentials**: `~/.config/aidevops/mcp-env.sh` (600 permissions)

**Critical Rules**:
- **Git check before edits**: See "MANDATORY: Pre-Edit Git Check" section above
- NEVER create files in `~/` root - use `~/.aidevops/.agent-workspace/work/[project]/` for files needed only with the current task.
- NEVER expose credentials in output/logs
- Confirm destructive operations before execution
- Store secrets ONLY in `~/.config/aidevops/mcp-env.sh`
- Re-read files immediately before editing (stale reads cause "file modified" errors)

**Quality Standards**: SonarCloud A-grade, ShellCheck zero violations

**SonarCloud Hotspot Patterns** (auto-excluded via `sonar-project.properties`):
- Scripts matching `*-helper.sh`, `*-setup.sh`, `*-cli.sh`, `*-verify.sh` are excluded from:
  - S5332 (clear-text protocol) - `http://localhost` for local dev
  - S6506 (HTTPS not enforced) - `curl|bash` for official installers
- Add `# SONAR:` comments for documentation, exclusions handle suppression

## Planning Workflow

**After completing planning/research**, use `/save-todo` to record the work.

The command auto-detects complexity and saves appropriately:
- **Simple** (< 2h, single action) → TODO.md only
- **Complex** (> 2h, multi-step) → PLANS.md + TODO.md reference

User confirms with numbered options to override if needed.

**Planning files:**

| File | Purpose |
|------|---------|
| `TODO.md` | All tasks (simple + plan references) |
| `todo/PLANS.md` | Complex execution plans with context |
| `todo/tasks/prd-*.md` | Product requirement documents |
| `todo/tasks/tasks-*.md` | Implementation task lists |

**Slash commands:** `/save-todo`, `/plan-status`, `/create-prd`, `/generate-tasks`, `/log-time-spent`, `/ready`, `/sync-beads`

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

**Task Dependencies (Beads integration):**

```markdown
- [ ] t001 First task
- [ ] t002 Second task blocked-by:t001
- [ ] t001.1 Subtask of t001
```

| Syntax | Meaning |
|--------|---------|
| `blocked-by:t001` | Task waits for t001 |
| `blocks:t002` | Task blocks t002 |
| `t001.1` | Subtask of t001 |

**Beads commands:** `/ready` (show unblocked tasks), `/sync-beads` (sync with graph)

**Full workflow:** See `workflows/plans.md` for details

## Git Workflow (File Changes)

**BEFORE making any file changes**: Follow the "MANDATORY: Pre-Edit Git Check" at the top of this file.

**After user confirms branch choice**:
1. Check `TODO.md` and `todo/PLANS.md` for matching tasks
2. Derive branch name from task/plan when available
3. Create branch and call `session-rename_sync_branch` tool to sync session name
4. Record `started:` timestamp in TODO.md if matching task exists
5. Read `workflows/git-workflow.md` for full workflow guidance

**Session tools** (OpenCode):
- `session-rename_sync_branch` - Auto-sync session name with current git branch (preferred)
- `session-rename` - Set custom session title

**Branch types**: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

**User prompts**: Always use numbered options (1, 2, 3...). Never use "[Enter] to confirm" - OpenCode requires typed input.

**Issue URLs**: Paste any GitHub/GitLab/Gitea issue URL to auto-setup branch.

**OpenCode GitHub/GitLab Integration**: Enable AI-powered issue/PR automation:

```bash
# Check setup status
~/.aidevops/agents/scripts/opencode-github-setup-helper.sh check

# GitHub: Install app + workflow
opencode github install

# Then use /oc in any issue/PR comment:
# /oc fix this bug → creates branch + PR automatically
```

See `tools/git/opencode-github.md` and `tools/git/opencode-gitlab.md` for details.

**After completing file changes**, offer numbered options:

1. Run preflight checks (`workflows/preflight.md`)
2. Skip preflight and commit directly (not recommended)
3. Continue making more changes

Only offer to commit after preflight passes or user explicitly skips.

**Special handling for `.agent/` files** (in aidevops repo or repos with local agents):
When modifying files in `.agent/` directory:
1. After commit, prompt: "Agent files changed. Run `./setup.sh` to deploy locally? [Y/n]"
2. In aidevops repo: `cd ~/Git/aidevops && ./setup.sh`
3. This ensures `~/.aidevops/agents/` stays in sync with source

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
| `onboarding.md` | Interactive setup wizard for new users |
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
| `wordpress/` | WordPress ecosystem (wordpress, wp-dev, wp-admin, localwp, mainwp, wp-preferred, scf) |
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
| `tools/git/` | Git platforms (github-cli, gitlab-cli, gitea-cli, github-actions, authentication, security, opencode-github, opencode-gitlab) |
| `tools/credentials/` | Credential management (list-keys, api-key-management, api-key-setup, vaultwarden) |
| `tools/opencode/` | OpenCode configuration, paths, oh-my-opencode integration |
| `tools/task-management/` | Task tracking (beads - graph visualization, dependencies) |
| `services/hosting/` | Hosting providers (hostinger, hetzner, cloudflare, cloudron, closte, 101domains, spaceship, localhost, dns-providers, domain-purchasing) |
| `services/email/` | Email services (ses) |
| `services/accounting/` | Accounting services (quickfile) |
| `workflows/` | Process guides (git-workflow, branch, plans, release, version-bump, bug-fixing, feature-development, pr, code-audit-remote, error-feedback, multi-repo-workspace) |
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
aidevops init beads              # Enable beads (includes planning)
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
- Planning complex work → `workflows/plans.md`
- Task dependencies/graphs → `tools/task-management/beads.md` (Beads integration)
- Specific service operations → `services/[type]/[provider].md`
- Code quality tasks → `tools/code-review/`
- WordPress work → `wordpress/`
- Release/versioning → `workflows/`
- Browser automation → `tools/browser/`
- MCP development → `build-mcp/`
- SEO analysis → `seo/` (keyword-research, google-search-console, dataforseo, serper, site-crawler, eeat-score, domain-research)
- Database schemas/migrations → `workflows/sql-migrations.md` (declarative schemas, auto-generated migrations)
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
| `beads-sync-helper.sh` | Sync TODO.md/PLANS.md with Beads graph |
| `todo-ready.sh` | Show tasks with no open blockers |

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

### Cross-Tool Compatibility

aidevops supports multiple discovery methods:

| Method | Tools | How It Works |
|--------|-------|--------------|
| **Claude Code Plugin** | Claude Code | `/plugin marketplace add marcusquinn/aidevops` |
| **Agent Skills (SKILL.md)** | Cursor, VS Code, GitHub Copilot | Auto-discovered from `~/.aidevops/agents/` |
| **OpenCode Agents** | OpenCode | Generated stubs in `~/.config/opencode/agent/` |
| **Manual** | All others | Point to `~/.aidevops/agents/AGENTS.md` |

### Quick Setup by Tool

| Tool | Configuration |
|------|---------------|
| **Claude Code** | `/plugin marketplace add marcusquinn/aidevops` then `/plugin install aidevops@aidevops` |
| **OpenCode** | Automatic via `setup.sh` → `generate-opencode-agents.sh` |
| **Cursor** | Auto-discovers SKILL.md files from configured paths |
| **VS Code** | GitHub Copilot discovers SKILL.md via Agent Skills |
| **Windsurf** | Point to `~/.aidevops/agents/AGENTS.md` or create local `.windsurfrules` |
| **Other tools** | Point to `~/.aidevops/agents/AGENTS.md` |

**Note**: Tool-specific files (`.cursorrules`, `.windsurfrules`, etc.) are not tracked in git. Create symlinks locally if needed.

## Development Workflows

For versioning, releases, and git operations:

| Task | Subagent |
|------|----------|
| Planning | `workflows/plans.md` |
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
