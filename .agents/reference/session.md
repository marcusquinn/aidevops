# Session & Environment — Detail Reference

Loaded on-demand for session management, browser automation, localhost, or quality workflows.
Core pointers are in `AGENTS.md`.

## Terminal Capabilities

Full PTY access: run any CLI (`vim`, `psql`, `ssh`, `htop`, dev servers, `opencode -p "subtask"`). Long-running: use `&`/`nohup`/`tmux`. Parallel AI: `tools/ai-assistants/opencode-server.md`.

## Session Completion

Run `/session-review` before ending. Suggest new sessions after PR merge, domain switch, or 3+ hours.

**Cleanup**: Commit/stash changes, run `wt merge` to clean merged worktrees.

**Full docs**: `workflows/session-manager.md`

## Context Compaction Resilience

When context is compacted (long sessions, autonomous loops), operational state is lost unless persisted to disk. Use `/checkpoint` to save and restore session state.

**Commands**:

- `/checkpoint` or `session-checkpoint-helper.sh save --task <id> --next <ids>` — save current state
- `session-checkpoint-helper.sh load` — reload state after compaction
- `session-checkpoint-helper.sh continuation` — generate a full continuation prompt for new sessions

**When to checkpoint**: After each task completion, before large operations, after PR creation/merge.

**Compaction survival rule**: See `prompts/build.txt` "Context Compaction Survival".

**Full docs**: `workflows/session-manager.md` "Compaction Resilience" section

## Git Workflow Detail

**Before edits**: Run pre-edit check (see AGENTS.md top).

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

**Worktree ownership** (CRITICAL): NEVER remove a worktree unless (a) you created it in this session, (b) it belongs to a task in your active batch, AND the task is deployed/complete, or (c) the user explicitly asks. Worktrees may belong to parallel sessions — removing them destroys another agent's working directory mid-work. When cleaning up, only touch worktrees for tasks you personally merged. Use `git worktree list` to see all worktrees but do NOT assume unrecognized ones are safe to remove. The ownership registry (`worktree-helper.sh registry list`) tracks which PID owns each worktree — `remove` and `clean` commands automatically refuse to touch worktrees owned by other live processes.

**Safety hooks** (Claude Code only): Destructive commands (`git reset --hard`, `rm -rf`, etc.) are blocked by a PreToolUse hook. Run `install-hooks.sh --test` to verify. See `workflows/git-workflow.md` "Destructive Command Safety Hooks" section.

**Full docs**: `workflows/git-workflow.md`, `tools/git/worktrunk.md`

## Browser Automation

Proactively use a browser for: dev server verification, form testing, deployment checks, frontend debugging. Read `tools/browser/browser-automation.md` for tool selection. Quick default: Playwright for dev testing, dev-browser for persistent login.

**CRITICAL: Never use curl/HTTP to verify frontend fixes.** Server returns 200 even when React crashes client-side because error boundaries render successfully. The crash happens during hydration which curl never executes. Always use browser screenshots (dev-browser agent, Playwright) to verify frontend fixes work.

## Localhost Standards

`.local` domains + SSL via Traefik + mkcert. See `services/hosting/local-hosting.md` (primary) or `services/hosting/localhost.md` (legacy).

## Bot Reviewer Feedback

AI suggestion verification: see `prompts/build.txt`. Dismiss incorrect suggestions with evidence; address valid ones.

## Quality Workflow

```text
Development → @code-standards → /code-simplifier → /linters-local → /pr review → /postflight
```

**Quick commands**: `linters-local.sh` (pre-commit), `/pr review` (full), `version-manager.sh release [type]`

## Agents & Subagents Detail

See `subagent-index.toon` for complete listing of agents, subagents, workflows, and scripts.

**Strategy**: Read subagents on-demand when tasks require domain expertise. This keeps context focused.

**Agent tiers** (user-created agents survive `aidevops update`):

| Tier | Location | Purpose |
|------|----------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | R&D, experimental, auto-created by orchestration tasks |
| **Custom** | `~/.aidevops/agents/custom/` | User's permanent private agents |
| **Shared** | `.agents/` in repo | Open-source, distributed to all users |

Orchestration agents can create drafts in `draft/` for reusable parallel processing context. See `tools/build-agent/build-agent.md` for the full lifecycle and promotion workflow.

## Security Detail

Security rules: see `prompts/build.txt`. Additional details:

- Config templates: `configs/*.json.txt` (committed), working: `configs/*.json` (gitignored)

**Full docs**: `tools/credentials/gopass.md`, `tools/credentials/api-key-setup.md`

## Working Directories

Working directory tree: see `prompts/build.txt`. Agent file locations:

- `~/.aidevops/agents/custom/` — User's permanent private agents (survives updates)
- `~/.aidevops/agents/draft/` — R&D, experimental agents (survives updates)
- `~/.aidevops/agents/` — Shared agents (deployed from repo, overwritten on update)
