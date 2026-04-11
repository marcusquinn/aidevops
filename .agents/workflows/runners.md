---
description: Dispatch workers for tasks, PRs, or issues via opencode run
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Dispatch one or more workers. Route by work type:

- **Code changes** (repo edits, tests, PRs) → `/full-loop`
- **Operational work** (reports, audits, monitoring, outreach) → direct command execution

Arguments: $ARGUMENTS

## Scope

Targeted dispatcher: resolves explicit items, launches one worker per item, shows dispatch table, stops. Does NOT run supervisor phases, auto-pickup, stale recovery, or audits — use `/pulse` for those (`scripts/commands/pulse.md`). Workers stay isolated; never touches source code, branches, or merge conflicts. Fix worker prompt or workflow on failure, not the dispatcher.

## Input Types

| Pattern | Type | Example |
|---------|------|---------|
| `GH#\d+` | GitHub issue/PR numbers | `/runners GH#267 GH#268` |
| `t\d+` | Task IDs from TODO.md | `/runners t083 t084 t085` |
| `#\d+` or PR URL | PR numbers | `/runners #382 #383` |
| Issue URL | GitHub issue | `/runners https://github.com/user/repo/issues/42` |
| Free text | Description | `/runners "Fix the login bug"` |

## Step 1: Resolve Items

```bash
gh issue view 267 --repo <slug> --json number,title,url
gh pr view 268 --repo <slug> --json number,title,headRefName,url
grep -E "^- \[ \] t083 " TODO.md
gh issue view 42 --repo user/repo --json number,title,url
```

## Step 2: Dispatch Workers

Use `headless-runtime-helper.sh run` — the **ONLY** valid dispatch path (NEVER bare `opencode run`; workers stop after PR creation, GH#5096). Use `--detach` for agent-to-agent dispatch to return control immediately.

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"

# Code task (Build+ is default; omit --agent)
$HELPER run \
  --detach \
  --role worker \
  --session-key "task-t083" \
  --dir ~/Git/<repo> \
  --title "t083: <description>" \
  --prompt "/full-loop t083 -- <description>"
# Returns immediately with: "Dispatched PID: 12345"
```

**Legacy (no `--detach`):** `$HELPER run ... </dev/null >>/tmp/worker-${session_key}.log 2>&1 &`

**Dispatch rules:**
- `--dir` must match the target repo
- `--agent <name>` for specialists; omit for code tasks (Build+ default)
- `--model` only if escalation is required by workflow policy

## Step 3: Show Dispatch Table

```text
## Dispatched Workers

| # | Item | Worker |
|---|------|--------|
| 1 | GH#267: <title> | dispatched |
| 2 | GH#268: <title> | dispatched |
```

Then stop. `/pulse` or a later operator action handles follow-up.
