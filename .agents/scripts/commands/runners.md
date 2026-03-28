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

**`/runners` is a targeted dispatch tool, not a supervisor.** It resolves the specified items, dispatches one worker per item, shows the dispatch table, and stops.

It does **NOT** run supervisor phases, auto-pickup unrelated tasks, stale claim recovery, phantom queue reconciliation, AI lifecycle evaluation, CodeRabbit pulse, or audit checks. For unattended operation that fills all available slots, use `/pulse` (see `scripts/commands/pulse.md`).

Workers are independent — they succeed or fail on their own. `/runners` never reads source code, implements features, runs tests, pushes branches, or resolves merge conflicts. If a worker fails, improve the worker's instructions, not the dispatcher.

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
# GitHub issue/PR numbers (GH#NNN format)
gh issue view 267 --repo <slug> --json number,title,url
gh pr view 268 --repo <slug> --json number,title,headRefName,url

# Task IDs — look up in TODO.md
grep -E "^- \[ \] t083 " TODO.md

# PR numbers — fetch from GitHub
gh pr view 382 --json number,title,headRefName,url

# Issue URLs — fetch from GitHub
gh issue view 42 --repo user/repo --json number,title,url
```

## Step 2: Dispatch Workers

Launch each worker via `headless-runtime-helper.sh run`. This is the **ONLY** correct dispatch path — it constructs the full lifecycle prompt, handles provider rotation, session persistence, and backoff. NEVER use bare `opencode run` — workers launched that way miss lifecycle reinforcement and stop after PR creation (GH#5096).

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"

# Code task (Build+ is default — omit --agent)
$HELPER run \
  --role worker \
  --session-key "task-t083" \
  --dir ~/Git/<repo> \
  --title "t083: <description>" \
  --prompt "/full-loop t083 -- <description>" &
sleep 2

# Specialist or operational task (no /full-loop for non-code ops)
$HELPER run \
  --role worker \
  --session-key "seo-weekly" \
  --dir ~/Git/<repo> \
  --agent SEO \
  --title "Weekly rankings" \
  --prompt "/seo-export --account client-a --format summary" &
sleep 2

# PR or issue
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

## Examples

All items in a single `/runners` invocation dispatch concurrently — each becomes a separate background process.

```bash
# Dispatch specific GitHub issues
/runners GH#267 GH#268

# Dispatch specific tasks
/runners t083 t084 t085

# Fix specific PRs
/runners #382 #383

# Work on a GitHub issue
/runners https://github.com/user/repo/issues/42

# Free-form task
/runners "Add rate limiting to the API endpoints"

# Multiple mixed items
/runners t083 #382 "Fix the login bug"
```
