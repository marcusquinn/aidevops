<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Session & Environment — Detail Reference

Loaded on-demand for session management, browser automation, localhost, or quality workflows. Core rules: `AGENTS.md`.

## Terminal Capabilities

Full PTY access: run any CLI (`vim`, `psql`, `ssh`, `htop`, dev servers). Long-running processes: use `&`, `nohup`, or `tmux`. Parallel AI dispatch: `tools/ai-assistants/opencode-server.md`.

## Session Lifecycle

- Run `/session-review` before ending.
- Suggest a new session after PR merge, domain switch, or 3+ hours.
- Cleanup: commit or stash changes, then run `wt merge` to clean merged worktrees.
- Full docs: `workflows/session-manager.md`.

## Context Compaction Resilience

Context compaction drops operational state unless written to disk. Use `/checkpoint` to persist and restore.

- Save: `/checkpoint` or `session-checkpoint-helper.sh save --task <id> --next <ids>`
- Load: `session-checkpoint-helper.sh load`
- Continuation prompt: `session-checkpoint-helper.sh continuation`
- Checkpoint after each task, before large operations, and after PR creation or merge.
- Full docs: `workflows/session-manager.md` "Compaction Resilience". Survival rules: `prompts/build.txt`.

## Git Workflow Detail

- Before edits: run the pre-edit check from `AGENTS.md`.
- After branch creation: check `TODO.md` for matching tasks, record `started:`, call `session-rename_sync_branch`, read `workflows/git-workflow.md`.

Worktrees are preferred for parallel work:

```bash
wt switch -c feature/my-feature   # Worktrunk (preferred)
worktree-helper.sh add feature/x  # Fallback
```

- After switching to a worktree, re-read files at the worktree path before editing. Edit tracking is path-specific.
- Worktree ownership: remove only if you created it this session, it's deployed/complete, or user asked. Ownership enforced by `worktree-helper.sh registry list`; `remove`/`clean` refuse live worktrees owned by other processes.
- Safety hooks block destructive commands (`git reset --hard`, `rm -rf`). Verify with `install-hooks.sh --test`. See `workflows/git-workflow.md` "Destructive Command Safety Hooks".
- Full docs: `workflows/git-workflow.md`, `tools/git/worktrunk.md`.

## Browser Automation

- Use a browser proactively for dev-server verification, form testing, deployment checks, and frontend debugging.
- Tool selection: `tools/browser/browser-automation.md`. Quick default: Playwright for dev testing, dev-browser for persistent login.
- Never use curl or raw HTTP to verify frontend fixes — a server can return 200 while React fails during hydration; browser screenshots are the required proof.

## Localhost Standards

Use `.local` domains with SSL via Traefik + mkcert. Primary doc: `services/hosting/local-hosting.md`. Legacy doc: `services/hosting/localhost.md`.

## Quality Workflow

```text
Development → @code-standards → /code-simplifier → /linters-local → /pr review → /postflight
```

Quick commands: `linters-local.sh` (pre-commit), `/pr review` (full), `version-manager.sh release [type]`. Bot reviewer feedback: follow `prompts/build.txt` — dismiss incorrect suggestions with evidence; address valid ones.

## Agents & Subagents

Full inventory: `subagent-index.toon`. Load subagents only when domain expertise is needed.

| Tier | Location | Purpose |
|------|----------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | R&D, experimental, auto-created by orchestration tasks |
| **Custom** | `~/.aidevops/agents/custom/` | User's permanent private agents |
| **Shared** | `.agents/` in repo | Open-source, distributed to all users |

Orchestration agents may create drafts for reusable parallel-processing context. Lifecycle: `tools/build-agent/build-agent.md`.

## Security & Working Directories

- Security rules: `prompts/build.txt`.
- Config templates: `configs/*.json.txt` (committed); working configs: `configs/*.json` (gitignored).
- Credential docs: `tools/credentials/gopass.md`, `tools/credentials/api-key-setup.md`.
