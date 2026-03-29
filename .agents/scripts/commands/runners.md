---
description: Dispatch workers for tasks, PRs, or issues via opencode run
agent: Build+
mode: subagent
---

Dispatch one or more workers to handle tasks. Route by type:

- **Code-change work** (repo edits, tests, PRs) -> `/full-loop`
- **Operational work** (reports, audits, monitoring, outreach) -> direct command execution (no PR ceremony)

Arguments: $ARGUMENTS

## Scope

**`/runners` is a targeted dispatch tool, not a supervisor.** It resolves specified items, dispatches one worker per item, shows the dispatch table, and stops. It does NOT run supervisor phases, auto-pickup, stale recovery, or audit checks — use `/pulse` for unattended slot-filling (see `scripts/commands/pulse.md`).

Workers are independent — `/runners` never touches source code, tests, branches, or merge conflicts. If a worker fails, improve the worker's instructions, not the dispatcher.

## Input Types

| Pattern | Type | Example |
|---------|------|---------|
| `GH#\d+` | GitHub issue/PR numbers | `/runners GH#267 GH#268` |
| `t\d+` | Task IDs from TODO.md | `/runners t083 t084 t085` |
| `#\d+` or PR URL | PR numbers | `/runners #382 #383` |
| Issue URL | GitHub issue | `/runners https://github.com/user/repo/issues/42` |
| Free text | Description | `/runners "Fix the login bug"` |

## Step 1: Resolve Items

For each input, resolve to a description:

```bash
gh issue view 267 --repo <slug> --json number,title,url
gh pr view 268 --repo <slug> --json number,title,headRefName,url
grep -E "^- \[ \] t083 " TODO.md
gh issue view 42 --repo user/repo --json number,title,url
```

## Step 2: Dispatch Workers

Launch each worker via `headless-runtime-helper.sh run` — the **ONLY** correct dispatch path. It constructs the full lifecycle prompt, handles provider rotation, session persistence, and backoff. NEVER use bare `opencode run` (workers miss lifecycle reinforcement and stop after PR creation — GH#5096).

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"

# Code task (Build+ default — omit --agent)
$HELPER run \
  --role worker \
  --session-key "task-t083" \
  --dir ~/Git/<repo> \
  --title "t083: <description>" \
  --prompt "/full-loop t083 -- <description>" &
sleep 2

# Specialist/operational task (no /full-loop)
$HELPER run \
  --role worker \
  --session-key "seo-weekly" \
  --dir ~/Git/<repo> \
  --agent SEO \
  --title "Weekly rankings" \
  --prompt "/seo-export --account client-a --format summary" &
sleep 2

# Issue dispatch
$HELPER run \
  --role worker \
  --session-key "issue-42" \
  --dir ~/Git/<repo> \
  --title "Issue #42: <title>" \
  --prompt "/full-loop Implement issue #42 (https://github.com/user/repo/issues/42) -- <description>" &
sleep 2
```

### Dispatch Rules

- `--dir ~/Git/<repo-name>` must match the repo the task belongs to
- `--agent <name>` routes to a specialist (SEO, Content, Marketing, etc.); omit for code tasks (defaults to Build+)
- `/full-loop` only for tasks needing repo code changes and PR traceability
- Do NOT add `--model` unless escalation is required by workflow policy
- Background each dispatch with `&` and `sleep 2` between to avoid thundering herd

## Step 3: Show Dispatch Table

After dispatching, show the user what was launched:

```text
## Dispatched Workers

| # | Item | Worker |
|---|------|--------|
| 1 | GH#267: <title> | dispatched |
| 2 | GH#268: <title> | dispatched |
```

Then stop. The next `/pulse` cycle (or the user) can check outcomes and dispatch follow-ups.
