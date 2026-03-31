# Session & Environment — Detail Reference

Loaded on-demand for session management, browser automation, localhost, or quality workflows. Core rules live in `AGENTS.md`.

## Terminal Capabilities

Full PTY access: run any CLI (`vim`, `psql`, `ssh`, `htop`, dev servers, `opencode -p "subtask"`).

- Long-running processes: use `&`, `nohup`, or `tmux`.
- Parallel AI dispatch: `tools/ai-assistants/opencode-server.md`.

## Session Lifecycle

- Run `/session-review` before ending.
- Suggest a new session after PR merge, domain switch, or 3+ hours.
- Cleanup: commit or stash changes, then run `wt merge` to clean merged worktrees.
- Full docs: `workflows/session-manager.md`.

## Context Compaction Resilience

Context compaction drops operational state unless it is written to disk. Use `/checkpoint` to persist and restore session state.

- Save: `/checkpoint` or `session-checkpoint-helper.sh save --task <id> --next <ids>`
- Load: `session-checkpoint-helper.sh load`
- Continuation prompt: `session-checkpoint-helper.sh continuation`
- Checkpoint after each task, before large operations, and after PR creation or merge.
- Survival rules: `prompts/build.txt` "Context Compaction Survival".
- Full docs: `workflows/session-manager.md` "Compaction Resilience".

## Git Workflow Detail

- Before edits: run the pre-edit check from `AGENTS.md`.
- After branch creation:
  1. Check `TODO.md` for matching tasks and record `started:`.
  2. Call `session-rename_sync_branch`.
  3. Read `workflows/git-workflow.md`.

Worktrees are preferred for parallel work:

```bash
wt switch -c feature/my-feature   # Worktrunk (preferred)
worktree-helper.sh add feature/x  # Fallback
```

- After switching to a worktree, re-read files at the worktree path before editing. Edit tracking is path-specific; a read from the main repo path does not authorize edits at the worktree path.
- After completing changes, offer: 1) Preflight checks 2) Skip preflight 3) Continue editing.
- Worktree ownership is critical: remove a worktree only if you created it in this session, it belongs to your active batch and is deployed or complete, or the user explicitly asked. Unknown worktrees may belong to parallel sessions. Use `git worktree list` for visibility only; ownership is enforced by `worktree-helper.sh registry list`, and `remove`/`clean` refuse live worktrees owned by other processes.
- Claude Code safety hooks block destructive commands such as `git reset --hard` and `rm -rf`. Verify with `install-hooks.sh --test`. See `workflows/git-workflow.md` "Destructive Command Safety Hooks".
- Full docs: `workflows/git-workflow.md`, `tools/git/worktrunk.md`.

## Browser Automation

- Use a browser proactively for dev-server verification, form testing, deployment checks, and frontend debugging.
- Tool selection: `tools/browser/browser-automation.md`.
- Quick default: Playwright for dev testing, dev-browser for persistent login.
- Never use curl or raw HTTP to verify frontend fixes. A server can return 200 while React fails during hydration; browser screenshots are the required proof.

## Localhost Standards

Use `.local` domains with SSL via Traefik + mkcert. Primary doc: `services/hosting/local-hosting.md`. Legacy doc: `services/hosting/localhost.md`.

## Bot Reviewer Feedback

Follow `prompts/build.txt` for AI suggestion verification. Dismiss incorrect suggestions with evidence; address valid ones.

## Quality Workflow

```text
Development → @code-standards → /code-simplifier → /linters-local → /pr review → /postflight
```

Quick commands: `linters-local.sh` (pre-commit), `/pr review` (full), `version-manager.sh release [type]`.

## Agents & Subagents

- Full inventory: `subagent-index.toon`.
- Strategy: load subagents only when domain expertise is needed.

| Tier | Location | Purpose |
|------|----------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | R&D, experimental, auto-created by orchestration tasks |
| **Custom** | `~/.aidevops/agents/custom/` | User's permanent private agents |
| **Shared** | `.agents/` in repo | Open-source, distributed to all users |

Orchestration agents may create drafts for reusable parallel-processing context. Lifecycle details: `tools/build-agent/build-agent.md`.

## Security & Working Directories

- Security rules: `prompts/build.txt`.
- Config templates: `configs/*.json.txt` (committed); working configs: `configs/*.json` (gitignored).
- Credential docs: `tools/credentials/gopass.md`, `tools/credentials/api-key-setup.md`.
- Working directory tree: `prompts/build.txt`.
- Agent locations:
  - `~/.aidevops/agents/custom/` — permanent private agents
  - `~/.aidevops/agents/draft/` — R&D and experimental agents
  - `~/.aidevops/agents/` — shared deployed agents overwritten on update
