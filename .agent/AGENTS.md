---
mode: subagent
---
# AI DevOps Framework - User Guide

**New to aidevops?** Type `/onboarding` to get started with an interactive setup wizard.

## 🛑 MANDATORY: Pre-Edit Git Check

> **Skip this section if you don't have Edit/Write/Bash tools** (e.g., Plan+ agent).
> Read-only agents should proceed directly to responding to the user.

**CRITICAL**: This check MUST be performed BEFORE:
- **Creating** new files
- **Editing** existing files
- **Writing** any content to disk
- Using Edit, Write, or Bash tools that modify files

Failure to follow this workflow is a bug in the AI assistant's behavior.

**Trigger words requiring this check**: create, add, write, update, modify, change, fix, implement, refactor.
If the user's request contains ANY of these, run the check FIRST.

**Self-check before any file operation**: Say "Checking git branch..." and run:

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
```

If the script outputs "STOP - ON PROTECTED BRANCH", you MUST NOT proceed with edits.

**Manual check if script unavailable:**

1. Run `git branch --show-current`
2. If on `main`, present this prompt and WAIT for user response:

> On `main`. Suggested branch: `{type}/{suggested-name}`
>
> 1. Create worktree (recommended - keeps main repo on main)
> 2. Use different branch name
> 3. Stay on `main` (docs-only, not recommended for code)

3. **Do NOT proceed until user replies with 1, 2, or 3**

**Loop mode (autonomous agents)**: Loop agents (`/full-loop`, `/ralph-loop`) use auto-decision to avoid stalling:

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "task description"
```

Auto-decision rules:
- **Docs-only tasks** (README, CHANGELOG, docs/, typos) -> Option 3 (stay on main)
- **Code tasks** (feature, fix, implement, refactor, enhance) -> Option 1 (create worktree automatically)

Exit codes: `0` = proceed, `1` = interactive stop, `2` = create worktree needed

Detection keywords:
- Docs-only: `readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`
- Code (overrides docs): `feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`, `helper`

**Why worktrees are the default**: The main repo directory (`~/Git/{repo}/`) should ALWAYS stay on `main`. This prevents:
- Uncommitted changes blocking branch switches
- Parallel sessions inheriting wrong branch state
- "Your local changes would be overwritten" errors

**When option 3 is acceptable**: Documentation-only changes (README, CHANGELOG, docs/), typo fixes, version bumps via release script, **planning files (TODO.md, todo/)**.
**When option 3 is NOT acceptable**: Any code changes, configuration files, scripts.

**Planning files exception**: TODO.md and todo/ can be edited directly on main and auto-committed:

```bash
~/.aidevops/agents/scripts/planning-commit-helper.sh "plan: add new task"
```

Planning files are metadata about work, not the work itself - they don't need PR review.

4. Create worktree: `wt switch -c {type}/{name}` (preferred) or `worktree-helper.sh add {type}/{name}` (fallback)
5. After creating branch, call `session-rename_sync_branch` tool

**Legacy checkout workflow**: If user explicitly requests `git checkout -b` instead of worktrees, warn them:
> Note: Checkout leaves main repo on feature branch. Remember to `git checkout main` when done, or use worktrees to avoid this.

**Why this matters**: Skipping this check causes direct commits to `main`, bypassing PR review.

**Main repo principle**: The directory `~/Git/{repo}/` should always stay on `main`. All feature work happens in worktree directories (`~/Git/{repo}-{type}-{name}/`). This ensures any session opening the main repo starts clean.

**Self-verification**: Before ANY file operation, ask yourself:
"Have I run pre-edit-check.sh in this session?" If unsure, run it NOW.

**Tool-level enforcement**: Before calling Edit, Write, or Bash (with file-modifying commands), you MUST have already confirmed you're on a feature branch. If the check hasn't been run this session, run it NOW before proceeding.

**Working in aidevops framework**: When modifying aidevops agents, you work in TWO locations:
- **Source**: `~/Git/aidevops/.agent/` - THIS is the git repo, check branch HERE
- **Deployed**: `~/.aidevops/agents/` - copy of source, not a git repo

Run pre-edit-check.sh in `~/Git/aidevops/` BEFORE any changes to either location.

---

## 🛑 MANDATORY: File Discovery

> **NEVER use `mcp_glob` when Bash is available.**

**Self-check before ANY file search**: "Am I about to use `mcp_glob`?" If yes, STOP and use:

| Use Case | Command | Why |
|----------|---------|-----|
| Git-tracked files | `git ls-files '<pattern>'` | Instant, most common case |
| Untracked/system files | `fd -e <ext>` or `fd -g '<pattern>'` | Fast, respects .gitignore |
| Content + file list | `rg --files -g '<pattern>'` | Fast, respects .gitignore |
| **Bash unavailable only** | `mcp_glob` tool | Last resort - CPU intensive |

**Why this matters**: `mcp_glob` is CPU-intensive on large codebases. Bash alternatives are instant.

**Only exception**: Agents without Bash tool (rare - even Plan+ has granular bash permissions for `git ls-files`, `fd`, `rg --files`).

Failure to follow this rule is a bug in the AI assistant's behavior.

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
- **File discovery**: See "MANDATORY: File Discovery" section above
- **Context budget**: Never consume >100K tokens on a single operation; for remote repos: fetch README first, check size with `gh api`, use `includePatterns`
- **Agent capability check**: Before edits, verify you have Edit/Write/Bash tools; if not, suggest switching to Build+
- NEVER create files in `~/` root - use `~/.aidevops/.agent-workspace/work/[project]/` for files needed only with the current task.
- NEVER expose credentials in output/logs
- Confirm destructive operations before execution
- Store secrets ONLY in `~/.config/aidevops/mcp-env.sh`
- Re-read files immediately before editing (stale reads cause "file modified" errors)

**Quality Standards**: SonarCloud A-grade, ShellCheck zero violations

**Localhost Standards** (for any local service setup):
- **Always check port first**: `localhost-helper.sh check-port <port>` before starting services
- **Use .local domains**: `myapp.local` not `localhost:3000` (enables password manager autofill)
- **Always use SSL**: Via Traefik proxy with mkcert certificates
- **Auto-find ports**: `localhost-helper.sh find-port <start>` if preferred port is taken
- See `services/hosting/localhost.md` for full setup guide

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

**Slash commands:** `/save-todo`, `/plan-status`, `/create-prd`, `/generate-tasks`, `/log-time-spent`, `/ready`, `/sync-beads`, `/remember`, `/recall`, `/session-review`, `/full-loop`, `/code-simplifier`, `/humanise`

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

**TODO.md branch strategy**: Stay on current branch for related work (discovered tasks, status updates). For unrelated backlog additions, offer branch choice if no uncommitted changes.

**Full workflow:** See `workflows/plans.md` for details

## Memory System

Cross-session memory using SQLite FTS5 for fast full-text search.

**Commands:**

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Store a memory with AI-assisted categorization |
| `/recall {query}` | Search memories by keyword |
| `/recall --recent` | Show 10 most recent memories |
| `/recall --stats` | Show memory statistics |

**Memory types:** `WORKING_SOLUTION`, `FAILED_APPROACH`, `CODEBASE_PATTERN`, `USER_PREFERENCE`, `TOOL_CONFIG`, `DECISION`, `CONTEXT`

**CLI:** `~/.aidevops/agents/scripts/memory-helper.sh [store|recall|stats|validate|prune|export]`

**Storage:** `~/.aidevops/.agent-workspace/memory/memory.db`

**Full docs:** See `memory/README.md` and `scripts/commands/remember.md`

## Git Workflow (File Changes)

**BEFORE making any file changes**: Follow the "MANDATORY: Pre-Edit Git Check" at the top of this file.

**After user confirms branch choice**:
1. Check `TODO.md` and `todo/PLANS.md` for matching tasks
2. Derive branch name from task/plan when available
3. Create branch and call `session-rename_sync_branch` tool to sync session name
4. Record `started:` timestamp in TODO.md if matching task exists
5. Read `workflows/git-workflow.md` for full workflow guidance
6. **Monitor scope**: If work diverges from branch purpose, suggest new branch

**Session tools** (OpenCode):
- `session-rename_sync_branch` - Auto-sync session name with current git branch (preferred)
- `session-rename` - Set custom session title

**Terminal tab title**: Auto-syncs with `repo/branch` via `pre-edit-check.sh`. Works with Tabby, iTerm2, Windows Terminal, Kitty, and most modern terminals. See `tools/terminal/terminal-title.md`.

**Parallel branch work** (git worktrees): For multiple terminals/sessions on different branches:

```bash
# ALWAYS check for wt first, use it if available
command -v wt &>/dev/null && wt switch -c feature/my-feature

# Worktrunk commands (preferred - install: brew install max-sixty/worktrunk/wt)
wt switch -c feature/my-feature   # Create worktree + cd into it
wt list                           # List with CI status
wt merge                          # Squash/rebase + cleanup

# Fallback: worktree-helper.sh (only if wt not installed)
~/.aidevops/agents/scripts/worktree-helper.sh add feature/my-feature
~/.aidevops/agents/scripts/worktree-helper.sh list
~/.aidevops/agents/scripts/worktree-helper.sh clean
```

See `workflows/worktree.md` for full workflow, `tools/git/worktrunk.md` for Worktrunk docs.

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

## Session Completion & Parallel Work

**Run `/session-review` before ending a session** to ensure:
- All objectives completed
- Workflow best practices followed
- Knowledge captured for future sessions
- Clear next steps identified

**Recognize session completion signals:**
- All session tasks marked `[x]` in TODO.md
- PR merged and release published
- User expresses gratitude ("thanks", "done", "that's all")
- Significant topic shift to unrelated work

**At natural completion points, suggest:**

```text
---
Session goals achieved:
- [x] {completed task 1}
- [x] {completed task 2}

Suggestions:
1. Run @agent-review to capture learnings
2. Start new session for clean context
3. For parallel work: `wt switch -c {type}/{name}` (or worktree-helper.sh if wt unavailable)
---
```

**When to suggest new sessions:**
- After PR merge + release
- When switching to unrelated domain
- After 3+ hours of continuous work
- When user requests unrelated task

**Session cleanup checklist** (before ending):
1. Commit or stash uncommitted changes
2. If in worktree: no action needed (worktree stays on its branch)
3. If used `git checkout -b` in main repo: `git checkout main` before ending
4. Run `wt list` then `wt merge` (or `worktree-helper.sh clean`) to remove merged worktrees

**Spawning parallel sessions** (for related but separate work):

```bash
# Create worktree + spawn new terminal (macOS)
wt switch -c feature/parallel-task  # preferred
# Or: ~/.aidevops/agents/scripts/worktree-helper.sh add feature/parallel-task
osascript -e 'tell application "Terminal" to do script "cd ~/Git/{repo}.feature-parallel-task && opencode"'

# Or background session
opencode run "Continue with task X" --agent Build+ &
```

See `workflows/session-manager.md` for full session lifecycle guidance.

## Main Agents

| Agent | Purpose |
|-------|---------|
| `plan-plus.md` | Read-only planning with semantic codebase search |
| `build-plus.md` | Enhanced Build with context tools |
| `aidevops.md` | Framework operations, meta-agents, setup |
| `onboarding.md` | Interactive setup wizard for new users |
| `seo.md` | SEO optimization and analysis |
| `content.md` | Content creation workflows |
| `research.md` | Research and analysis tasks |
| `marketing.md` | Marketing strategy, email campaigns, automation (FluentCRM) |
| `sales.md` | Sales operations, CRM, pipeline management (FluentCRM) |
| `legal.md` | Legal compliance |
| `accounts.md` | Financial operations |
| `health.md` | Health and wellness |
| `social-media.md` | Social media management |

## Subagent Folders

Subagents provide specialized capabilities. Read them when tasks require domain expertise.

| Folder | Purpose | Key Subagents |
|--------|---------|---------------|
| `aidevops/` | Framework internals - extending aidevops, adding MCPs, architecture decisions | setup, architecture, add-new-mcp-to-aidevops, troubleshooting, mcp-integrations |
| `memory/` | Cross-session memory - SQLite FTS5 storage, /remember and /recall commands | README (system docs) |
| `seo/` | Search optimization - keyword research, rankings, site audits, E-E-A-T scoring, sitemap submission | dataforseo, serper, google-search-console, gsc-sitemaps, site-crawler, eeat-score, domain-research |
| `content/` | Content creation - copywriting standards, editorial guidelines, tone of voice, AI writing pattern removal | guidelines, humanise |
| `tools/content/` | Content tools - summarization, extraction, processing | summarize |
| `tools/social-media/` | Social media tools - X/Twitter CLI, posting, reading | bird |
| `tools/build-agent/` | Agent design - composing efficient agents, reviewing agent instructions | build-agent, agent-review |
| `tools/build-mcp/` | MCP development - creating Model Context Protocol servers and tools | build-mcp, api-wrapper, server-patterns, transports, deployment |
| `tools/ai-assistants/` | AI tool integration - configuring assistants, CAPTCHA solving, multi-modal agents | agno, capsolver, windsurf, configuration, status |
| `tools/ai-orchestration/` | AI orchestration frameworks - visual builders, multi-agent teams, workflow automation, DSL orchestration | overview, langflow, crewai, autogen, openprose, packaging |
| `tools/browser/` | Browser automation - web scraping, testing, screenshots, form filling, cookie extraction, macOS GUI automation | agent-browser, stagehand, playwright, playwriter, crawl4ai, dev-browser, pagespeed, chrome-devtools, sweet-cookie, peekaboo |
| `tools/ui/` | UI components - component libraries, design systems, frontend debugging, hydration errors | shadcn, ui-skills, frontend-debugging |
| `tools/code-review/` | Code quality - linting, security scanning, style enforcement, PR reviews | code-standards, code-simplifier, codacy, coderabbit, qlty, snyk, secretlint, auditing |
| `tools/context/` | Context optimization - semantic search, codebase indexing, token efficiency | osgrep, augment-context-engine, context-builder, context7, toon, dspy, llm-tldr |
| `tools/conversion/` | Format conversion - document transformation between formats | pandoc |
| `tools/data-extraction/` | Data extraction - scraping business data, Google Maps, reviews | outscraper |
| `tools/deployment/` | Deployment automation - self-hosted PaaS, serverless, CI/CD | coolify, coolify-cli, vercel |
| `tools/git/` | Git operations - GitHub/GitLab/Gitea CLIs, Actions, worktrees, AI PR automation | github-cli, gitlab-cli, gitea-cli, github-actions, worktrunk, opencode-github, opencode-gitlab |
| `tools/credentials/` | Secret management - API keys, password vaults, environment variables | api-key-setup, api-key-management, vaultwarden, environment-variables |
| `tools/opencode/` | OpenCode config - CLI setup, plugins, authentication, Oh-My-OpenCode extensions | opencode, opencode-anthropic-auth, oh-my-opencode |
| `tools/task-management/` | Task tracking - dependency graphs, blocking relationships, visual planning | beads |
| `tools/terminal/` | Terminal integration - tab titles, git context display | terminal-title |
| `tools/automation/` | macOS automation - AppleScript, JXA, accessibility API, app control | mac, macos-automator |
| `tools/wordpress/` | WordPress ecosystem - local dev, fleet management, plugin curation, custom fields | wp-dev, wp-admin, localwp, mainwp, wp-preferred, scf |
| `services/hosting/` | Hosting providers - DNS, domains, cloud servers, managed WordPress | hostinger, hetzner, cloudflare, cloudron, closte, 101domains, spaceship |
| `services/email/` | Email services - transactional email, deliverability | ses |
| `services/communications/` | Communications platform - SMS, voice, WhatsApp, verify, recordings | twilio, telfon |
| `services/crm/` | CRM integration - contact management, email marketing, automation | fluentcrm |
| `services/analytics/` | Website analytics - GA4 reporting, traffic analysis, real-time data, e-commerce tracking | google-analytics |
| `services/accounting/` | Accounting integration - invoicing, expenses, financial reports | quickfile |
| `workflows/` | Development processes - branching, releases, PR reviews, quality gates | git-workflow, plans, release, version-bump, pr, review-issue-pr, preflight, postflight, ralph-loop, session-review |
| `templates/` | Document templates - PRDs, task lists, planning documents | prd-template, tasks-template, plans-template, todo-template |
| `workflows/branch/` | Branch conventions - naming, purpose, merge strategies per branch type | feature, bugfix, hotfix, refactor, chore, experiment, release |
| `scripts/commands/` | Slash commands - save-todo, remember, recall, code-simplifier, humanise and other interactive commands | save-todo, remember, recall, code-simplifier, humanise |

<!-- AI-CONTEXT-END -->

## Getting Started

**Installation:**

```bash
# npm (recommended)
npm install -g aidevops && aidevops update

# Homebrew
brew install marcusquinn/tap/aidevops && aidevops update

# curl (manual)
bash <(curl -fsSL https://aidevops.sh)
```

This installs the CLI and deploys agents to `~/.aidevops/agents/`.

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
| `aidevops upgrade-planning` | Upgrade TODO.md/PLANS.md to latest templates |
| `aidevops features` | List available features |
| `aidevops status` | Check installation status |
| `aidevops update` | Update framework + check registered projects |
| `aidevops upgrade` | Alias for update |
| `aidevops repos` | List registered projects |
| `aidevops repos add` | Register current project |
| `aidevops detect` | Find unregistered aidevops projects |
| `aidevops update-tools` | Check for outdated tools |
| `aidevops uninstall` | Remove aidevops |

**Project tracking:** When you run `aidevops init`, the project is registered in `~/.config/aidevops/repos.json`. Running `aidevops update` will check all registered projects and offer to update their `.aidevops.json` version.

**Auto-detection:** When you clone a repo that has `.aidevops.json`, the CLI will suggest registering it. Run `aidevops detect` to scan `~/Git/` for unregistered projects.

For AI-assisted setup guidance, see `aidevops/setup.md`.

## Progressive Disclosure

**Strategy**: The AI-CONTEXT section above contains essential information for most tasks. Read subagents only when tasks require domain expertise - this keeps context focused and reduces token usage.

**How to use subagents**:
1. Check the "Subagent Folders" table above for the relevant domain
2. Read the specific subagent file when you need detailed guidance
3. Subagents are also available via Task tool for delegation (filtered per-agent to reduce overhead)

**When to read subagents:**

| Task Domain | Read These |
|-------------|------------|
| Planning complex work | `workflows/plans.md`, `tools/task-management/beads.md` |
| Code quality/reviews | `tools/code-review/code-standards.md`, then specific tools as needed |
| External issues/PRs | `workflows/review-issue-pr.md` (triage external contributions) |
| Git operations | `workflows/git-workflow.md`, `tools/git/github-cli.md` |
| Release/versioning | `workflows/release.md`, `workflows/version-bump.md` |
| Browser automation | `tools/browser/stagehand.md` or `tools/browser/playwright.md` |
| macOS GUI automation | `tools/browser/peekaboo.md` (screen capture, native app control) |
| Frontend debugging | `tools/ui/frontend-debugging.md` (hydration errors, monorepo gotchas) |
| WordPress work | `tools/wordpress/wp-dev.md`, `tools/wordpress/mainwp.md` |
| SEO analysis | `seo/dataforseo.md`, `seo/google-search-console.md` |
| Sitemap submission | `seo/gsc-sitemaps.md` |
| Website analytics | `services/analytics/google-analytics.md` (GA4 reports, traffic, conversions) |
| CRM/email marketing | `services/crm/fluentcrm.md` |
| MCP development | `tools/build-mcp/build-mcp.md`, `tools/build-mcp/server-patterns.md` |
| Agent design | `tools/build-agent/build-agent.md`, `tools/build-agent/agent-review.md` |
| Database migrations | `workflows/sql-migrations.md` |
| Framework internals | `aidevops/architecture.md` (when working in `~/Git/aidevops/`) |
| Content summarization | `tools/content/summarize.md` |
| X/Twitter automation | `tools/social-media/bird.md` |
| macOS automation | `tools/automation/mac.md` (AppleScript, JXA, app control) |

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
| `ralph-loop-helper.sh` | Iterative AI development loops (Ralph technique) |
| `full-loop-helper.sh` | End-to-end development loop (task → PR → deploy) |
| `session-review-helper.sh` | Gather session context for completeness review |
| `humanise-update-helper.sh` | Check for upstream updates to humanise subagent |

## Quality Workflow

```text
Development → @code-standards (reference)
     ↓
Post-edit → /code-simplifier (refine)
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
| Post-edit | `/code-simplifier` | Simplify and refine code |
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

**MCP Token Optimization**: Disable heavy MCPs globally, enable per-agent. See `tools/build-agent/build-agent.md` for patterns.

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
| Iterative AI loops | `workflows/ralph-loop.md` |

**Quick commands:**

```bash
# Version bump and release
.agent/scripts/version-manager.sh release [major|minor|patch]

# Local linting before commit
.agent/scripts/linters-local.sh

# Full PR review (orchestrates all checks)
/pr review
```
