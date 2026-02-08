---
mode: subagent
---
# AI DevOps Framework - User Guide

**New to aidevops?** Type `/onboarding` to get started with an interactive setup wizard.

**Supported tools:** [OpenCode](https://opencode.ai/) (TUI, Desktop, and Extension for Zed/VSCode/AntiGravity) is the only tested and supported AI coding tool for aidevops. The claude-code CLI is used as a companion tool called from within OpenCode. aidevops is also available in the Claude marketplace.

**Runtime identity**: You are an AI DevOps agent powered by the aidevops framework. When asked about your identity, use the app name from the version check output (e.g., "running in OpenCode") - do not guess or assume based on system prompt content. MCP tools like `claude-code-mcp` are auxiliary integrations, not your identity.

**Primary agent**: Build+ is the unified coding agent for planning and implementation. It detects intent automatically:
- "What do you think..." / "How should we..." → Deliberation mode (research, discuss)
- "Implement X" / "Fix Y" / "Add Z" → Execution mode (code changes)
- Ambiguous → Asks for clarification

**Specialist subagents**: Use `@aidevops` for framework operations, `@seo` for SEO tasks, `@wordpress` for WordPress, etc.

## MANDATORY: Pre-Edit Git Check

> **Skip if you don't have Edit/Write/Bash tools**.

**CRITICAL**: Before creating, editing, or writing ANY file, run:

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
```

Exit 0 = proceed. Exit 1 = STOP (on main). Exit 2 = create worktree. Exit 3 = warn user.

**Loop mode**: `pre-edit-check.sh --loop-mode --task "description"`

**Full details**: Read `workflows/pre-edit.md` for interactive prompts, worktree creation, and edge cases.

**Self-verification**: Your FIRST step before any Edit/Write MUST be to run this script. If you are about to edit a file and have not yet run pre-edit-check.sh in this session, STOP and run it now. No exceptions — including TODO.md and planning files (the script handles exception logic, not you).

**Subagent write restrictions**: Subagents invoked via the Task tool cannot run `pre-edit-check.sh` (many lack `bash: true`). When on `main`/`master`, subagents with `write: true` may ONLY write to: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. All other writes must be returned as proposed edits for the calling agent to apply in a worktree.

---

## MANDATORY: File Discovery

> **NEVER use `mcp_glob` when Bash is available.**

| Use Case | Command |
|----------|---------|
| Git-tracked files | `git ls-files '<pattern>'` |
| Untracked/system files | `fd -e <ext>` or `fd -g '<pattern>'` |
| Content + file list | `rg --files -g '<pattern>'` |
| **Bash unavailable only** | `mcp_glob` tool (last resort) |

---

## Terminal Capabilities

The Bash tool provides full PTY access. You can run any CLI autonomously:

| Category | Examples |
|----------|----------|
| **Editors** | `vim`, `nano`, `emacs` |
| **Database shells** | `psql`, `mysql`, `redis-cli`, `mongosh` |
| **Remote sessions** | `ssh user@host`, `mosh` |
| **Monitoring** | `htop`, `tail -f`, `watch`, `less` |
| **Dev servers** | `npm run dev`, `cargo watch`, `flask run` |
| **Nested AI** | `opencode -p "subtask"` (spawns subagent in same TUI) |

For long-running processes: use `&`, `nohup`, or `screen`/`tmux`. For parallel AI dispatch: use OpenCode server API (`tools/ai-assistants/opencode-server.md`).

---

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: DevOps automation across multiple services
- **Getting Started**: `/onboarding` - Interactive setup wizard
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Secrets**: `aidevops secret` (gopass encrypted) or `~/.config/aidevops/credentials.sh` (plaintext fallback)
- **Subagent Index**: `subagent-index.toon` (agents, subagents, workflows, scripts)

**Critical Rules**:
- Git check before edits (see above)
- File discovery via Bash (see above)
- **ALWAYS Read before Edit/Write** - Edit and Write tools FAIL if the file hasn't been Read in this conversation. Read the file first, then edit. No exceptions.
- Re-read files immediately before editing (stale reads cause errors)
- Context budget: Never >100K tokens per operation
- NEVER create files in `~/` root - use `~/.aidevops/.agent-workspace/work/[project]/`
- NEVER expose credentials in output/logs
- Confirm destructive operations before execution

**Quality**: SonarCloud A-grade, ShellCheck zero violations, `local var="$1"` pattern, explicit returns, blank lines around code blocks (MD031).

## Planning & Tasks

Use `/save-todo` after planning. Auto-detects complexity:
- **Simple** → TODO.md only
- **Complex** → PLANS.md + TODO.md reference

**Key commands**: `/save-todo`, `/ready`, `/sync-beads`, `/plan-status`, `/create-prd`, `/generate-tasks`

**Task format**: `- [ ] t001 Description @owner #tag ~4h (ai:2h test:1h) started:ISO blocked-by:t002`

**Dependencies**: `blocked-by:t001`, `blocks:t002`, `t001.1` (subtask)

**After ANY TODO/planning edit**: Commit and push immediately. Planning-only files (TODO.md, todo/) go directly to main — no branch, no PR. Mixed changes (planning + non-exception files) use a worktree. NEVER `git checkout -b` in the main repo. See `workflows/plans.md` "Commit and Push After TODO Changes" section.

**Full docs**: `workflows/plans.md`, `tools/task-management/beads.md`

## Memory

Cross-session SQLite FTS5 memory. Commands: `/remember {content}`, `/recall {query}`, `/recall --recent`

**CLI**: `memory-helper.sh [store|recall|log|stats|prune|consolidate|export]`

**Session distillation**: `session-distill-helper.sh auto` (extract learnings at session end)

**Auto-capture log**: `/memory-log` or `memory-helper.sh log` (review auto-captured memories)

**Full docs**: `memory/README.md`

### MANDATORY: Proactive Memory Triggers

**You MUST suggest `/remember` when you detect these patterns:**

| Trigger | Memory Type | Example |
|---------|-------------|---------|
| Solution found after debugging | `WORKING_SOLUTION` | "That fixed it! Want me to remember this?" |
| User states a preference | `USER_PREFERENCE` | "I'll remember you prefer tabs over spaces" |
| Workaround discovered | `WORKING_SOLUTION` | "This workaround worked - should I save it?" |
| Failed approach identified | `FAILED_APPROACH` | "That didn't work - remember to avoid this?" |
| Architecture decision made | `DECISION` | "Good decision - want me to remember why?" |
| Tool configuration worked | `TOOL_CONFIG` | "That config worked - save for next time?" |

**Format**: After detecting a trigger, suggest:

```text
Want me to remember this? /remember {concise description}
```

**Do NOT wait for user to ask** - proactively offer to remember valuable learnings.

### Auto-Capture with --auto Flag

When storing memories triggered by the patterns above, use the `--auto` flag to distinguish from manual `/remember` entries:

```bash
memory-helper.sh store --auto --type "WORKING_SOLUTION" --content "Fixed CORS with nginx headers" --tags "cors,nginx"
```

**Privacy**: Content is automatically filtered before storage:

- `<private>...</private>` blocks are stripped
- Content matching secret patterns (API keys, tokens) is rejected
- Never auto-capture credentials, passwords, or sensitive config values

## Inter-Agent Mailbox

SQLite-backed async communication between parallel agent sessions.

**CLI**: `mail-helper.sh [send|check|read|archive|prune|status|register|deregister|agents|migrate]`

**Message types**: task_dispatch, status_report, discovery, request, broadcast

**Lifecycle**: send → check → read → archive (history preserved, prune is manual)

**Runner integration**: Runners automatically check inbox before work and send status reports after. Unread messages are prepended as context to the runner's prompt.

**Storage**: `mail-helper.sh prune` shows storage report. Use `--force` to delete old archived messages. Migration from TOON files runs automatically on `aidevops update`.

## MCP On-Demand Loading

MCPs disabled globally, enabled per-agent via YAML frontmatter.

**Discovery**: `mcp-index-helper.sh search "capability"` or `mcp-index-helper.sh get-mcp "tool-name"`

**Full docs**: `tools/context/mcp-discovery.md`

## Git Workflow

**Before edits**: Run pre-edit check (see top of file).

**After branch creation**:
1. Check TODO.md for matching tasks, record `started:` timestamp
2. Call `session-rename_sync_branch` tool
3. Read `workflows/git-workflow.md` for full guidance

**Worktrees** (preferred for parallel work):

```bash
wt switch -c feature/my-feature   # Worktrunk (preferred)
worktree-helper.sh add feature/x  # Fallback
```

**After switching to a worktree**: Re-read any file at its worktree path before editing. The Edit tool tracks reads by exact absolute path — a read from the main repo path does NOT satisfy the worktree path.

**After completing changes**, offer: 1) Preflight checks 2) Skip preflight 3) Continue editing

**Branch types**: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

**Full docs**: `workflows/git-workflow.md`, `tools/git/worktrunk.md`

## Session Completion

Run `/session-review` before ending. Suggest new sessions after PR merge, domain switch, or 3+ hours.

**Cleanup**: Commit/stash changes, run `wt merge` to clean merged worktrees.

**Full docs**: `workflows/session-manager.md`

## Agents & Subagents

See `subagent-index.toon` for complete listing of agents, subagents, workflows, and scripts.

**Strategy**: Read subagents on-demand when tasks require domain expertise. This keeps context focused.

**Agent tiers** (user-created agents survive `aidevops update`):

| Tier | Location | Purpose |
|------|----------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | R&D, experimental, auto-created by orchestration tasks |
| **Custom** | `~/.aidevops/agents/custom/` | User's permanent private agents |
| **Shared** | `.agents/` in repo | Open-source, distributed to all users |

Orchestration agents can create drafts in `draft/` for reusable parallel processing context. See `tools/build-agent/build-agent.md` for the full lifecycle and promotion workflow.

**Progressive disclosure by domain**:

| Domain | Read |
|--------|------|
| Planning | `workflows/plans.md`, `tools/task-management/beads.md` |
| Code quality | `tools/code-review/code-standards.md` |
| Git/PRs | `workflows/git-workflow.md`, `tools/git/github-cli.md` |
| Releases | `workflows/release.md`, `workflows/version-bump.md` |
| Browser | `tools/browser/browser-automation.md` (decision tree, then tool-specific subagent) |
| WordPress | `tools/wordpress/wp-dev.md`, `tools/wordpress/mainwp.md` |
| SEO | `seo/dataforseo.md`, `seo/google-search-console.md` |
| Video | `tools/video/video-prompt-design.md`, `tools/video/remotion.md`, `tools/video/higgsfield.md` |
| Voice | `tools/voice/speech-to-speech.md`, `voice-helper.sh talk` (voice bridge) |
| Cloud GPU | `tools/infrastructure/cloud-gpu.md` |
| Parallel agents | `tools/ai-assistants/headless-dispatch.md`, `tools/ai-assistants/runners/` |
| MCP dev | `tools/build-mcp/build-mcp.md` |
| Agent design | `tools/build-agent/build-agent.md` |
| Framework | `aidevops/architecture.md` |

<!-- AI-CONTEXT-END -->

## Getting Started

**Installation:**

```bash
# npm (recommended)
npm install -g aidevops && aidevops update

# Homebrew
brew install marcusquinn/tap/aidevops && aidevops update

# curl (manual - download then execute, not piped)
curl -fsSL https://aidevops.sh -o /tmp/aidevops-setup.sh && bash /tmp/aidevops-setup.sh
```

**Initialize in any project:**

```bash
aidevops init                    # Enable all features
aidevops init planning           # Enable only planning
aidevops init beads              # Enable beads (includes planning)
aidevops features                # List available features
```

**CLI**: `aidevops [init|update|status|repos|skill|detect|features|uninstall]`

## Bot Reviewer Feedback

AI code review bots (Gemini, CodeRabbit, Copilot) can provide incorrect suggestions. **Never blindly implement bot feedback.** Verify factual claims (versions, paths, APIs) against runtime/docs/project conventions before acting. Dismiss incorrect suggestions with evidence; address valid ones.

## Quality Workflow

```text
Development → @code-standards → /code-simplifier → /linters-local → /pr review → /postflight
```

**Quick commands**: `linters-local.sh` (pre-commit), `/pr review` (full), `version-manager.sh release [type]`

## Skills & Cross-Tool

Import community skills: `aidevops skill add <source>` (→ `*-skill.md` suffix)

**Cross-tool**: Claude marketplace plugin, Agent Skills (SKILL.md), OpenCode agents, manual AGENTS.md reference.

**Full docs**: `scripts/commands/add-skill.md`

## Security

- **Encrypted secrets** (recommended): `aidevops secret` (gopass backend, GPG-encrypted)
- **Plaintext fallback**: `~/.config/aidevops/credentials.sh` (600 permissions)
- Config templates: `configs/*.json.txt` (committed), working: `configs/*.json` (gitignored)
- Confirm destructive operations before execution

**Secret handling rule**: When a user needs to store a secret, ALWAYS instruct them to run `aidevops secret set NAME` at their terminal. NEVER accept secret values in conversation context. NEVER run `gopass show`, `cat credentials.sh`, or any command that prints secret values.

**Full docs**: `tools/credentials/gopass.md`, `tools/credentials/api-key-setup.md`

## Working Directories

```text
~/.aidevops/
├── agents/                    # Deployed agent files
│   ├── custom/                # User's private agents (survives updates)
│   ├── draft/                 # Experimental/R&D agents (survives updates)
│   └── ...                    # Shared agents (deployed from repo)
└── .agent-workspace/
    ├── work/[project]/        # Persistent project files
    ├── tmp/session-*/         # Temporary session files
    ├── mail/                  # Inter-agent mailbox (SQLite: mailbox.db)
    └── memory/                # Cross-session patterns (SQLite FTS5)
```

## Browser Automation

**When to use a browser** (proactively, without being asked):
- Verifying a dev server works after changes (navigate, check content, screenshot if errors)
- Testing forms, auth flows, or UI after code changes
- Logging into websites to submit content, manage accounts, or extract data
- Verifying deployments are live and rendering correctly
- Debugging frontend issues (check console errors, network requests)

**How to choose a tool**: Read `tools/browser/browser-automation.md` for the full decision tree. Quick defaults:
- **Dev testing** (your app): Playwright direct (fastest) or dev-browser (persistent login)
- **Website interaction** (login, submit, manage): dev-browser (persistent) or Playwriter (your extensions/passwords)
- **Data extraction**: Crawl4AI (bulk) or Playwright (interactive first)
- **Debugging**: Chrome DevTools MCP paired with dev-browser

**AI page understanding** (how to "see" the page without vision tokens):
- Use ARIA snapshots (~0.01s, 50-200 tokens) for forms, navigation, interactive elements
- Use text extraction (~0.002s) for reading content
- Use screenshots only for visual debugging or when layout matters

**Benchmarks**: Read `tools/browser/browser-benchmark.md` to re-run if tools are updated.

## Localhost Standards

- Check port first: `localhost-helper.sh check-port <port>`
- Use `.local` domains (enables password manager autofill)
- Always SSL via Traefik + mkcert
- See `services/hosting/localhost.md`
