---
description: Dispatch workers for tasks, PRs, or issues via opencode run
agent: Build+
mode: subagent
---

Dispatch one or more workers. Route by work type:

- **Code changes** (repo edits, tests, PRs) -> `/full-loop`
- **Operational work** (reports, audits, monitoring, outreach) -> direct command execution

Arguments: $ARGUMENTS

## Scope

**`/runners` is a targeted dispatcher, not a supervisor.** It resolves explicit items, launches one worker per item, shows the dispatch table, and stops. It does NOT run supervisor phases, auto-pickup, stale recovery, or audits. Use `/pulse` for unattended slot-filling (`scripts/commands/pulse.md`).

Workers stay isolated: `/runners` never touches source code, tests, branches, or merge conflicts. If a worker fails, fix the worker prompt or workflow, not the dispatcher.

## Input Types

| Pattern | Type | Example |
|---------|------|---------|
| `GH#\d+` | GitHub issue/PR numbers | `/runners GH#267 GH#268` |
| `t\d+` | Task IDs from TODO.md | `/runners t083 t084 t085` |
| `#\d+` or PR URL | PR numbers | `/runners #382 #383` |
| Issue URL | GitHub issue | `/runners https://github.com/user/repo/issues/42` |
| Free text | Description | `/runners "Fix the login bug"` |

## Step 1: Resolve Items

Resolve each input to a description:

```bash
gh issue view 267 --repo <slug> --json number,title,url
gh pr view 268 --repo <slug> --json number,title,headRefName,url
grep -E "^- \[ \] t083 " TODO.md
gh issue view 42 --repo user/repo --json number,title,url
```

## Step 2: Dispatch Workers

Launch each worker via `headless-runtime-helper.sh run` — the **ONLY** valid dispatch path. It builds the lifecycle prompt, handles provider rotation, preserves sessions, and applies backoff. NEVER use bare `opencode run` or workers may stop after PR creation (GH#5096).

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"

# Code task (Build+ is default; omit --agent)
$HELPER run \
  --role worker \
  --session-key "task-t083" \
  --dir ~/Git/<repo> \
  --title "t083: <description>" \
  --prompt "/full-loop t083 -- <description>" &
sleep 2

# Specialist or operational task (no /full-loop)
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

- `--dir ~/Git/<repo-name>` must match the target repo
- `--agent <name>` routes to a specialist; omit it for code tasks (Build+ default)
- `/full-loop` only for tasks needing repo code changes and PR traceability
- Do NOT add `--model` unless escalation is required by workflow policy
- Background each dispatch with `&`, then `sleep 2`, to avoid thundering herd

## Step 3: Show Dispatch Table

After dispatch, show what was launched:

```text
## Dispatched Workers

| # | Item | Worker |
|---|------|--------|
| 1 | GH#267: <title> | dispatched |
| 2 | GH#268: <title> | dispatched |
```

Then stop. `/pulse` or a later operator action handles follow-up.
