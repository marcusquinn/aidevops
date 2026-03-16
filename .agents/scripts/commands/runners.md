---
description: Dispatch workers for tasks, PRs, or issues via opencode run
agent: Build+
mode: subagent
---

Dispatch one or more workers to handle tasks. Pick the execution mode per task type:

- **Code-change work** (repo edits, tests, PRs) -> `/full-loop`
- **Operational work** (reports, audits, monitoring, outreach) -> direct command execution (no PR ceremony)

Arguments: $ARGUMENTS

## How It Works

The runners system is intentionally simple:

1. **You tell it what to work on** (task IDs, PR numbers, issue URLs, or descriptions)
2. **It dispatches `opencode run` for each item** — one worker per task
3. **Code workers** handle branch -> implementation -> PR -> CI -> merge
4. **Ops workers** execute the requested SOP/command and report outcomes
4. **No databases, no state machines, no complex bash pipelines**

> **Automated mode:** For unattended operation and full supervisor behaviour (auto-pickup, capacity management, lifecycle evaluation), use `/pulse`. See `scripts/commands/pulse.md` for the full spec.

## Interactive Mode: `/runners`

**Scope boundary:** When invoked as `/runners`, ONLY resolve and dispatch the items explicitly specified in the arguments. Do NOT run supervisor phases, auto-pickup additional tasks, lifecycle evaluation, quality sweeps, or CodeRabbit pulse. Dispatch exactly the requested items and stop.

For manual dispatch of specific work items.

### Input Types

| Pattern | Type | Example |
|---------|------|---------|
| `t\d+` | Task IDs from TODO.md | `/runners t083 t084 t085` |
| `#\d+` or PR URL | PR numbers | `/runners #382 #383` |
| Issue URL | GitHub issue | `/runners https://github.com/user/repo/issues/42` |
| Free text | Description | `/runners "Fix the login bug"` |

### Step 1: Resolve What to Work On

For each input item, resolve it to a description:

```bash
# Task IDs — look up in TODO.md
grep -E "^- \[ \] t083 " TODO.md

# PR numbers — fetch from GitHub
gh pr view 382 --json number,title,headRefName,url

# Issue URLs — fetch from GitHub
gh issue view 42 --repo user/repo --json number,title,url
```

### Step 2: Dispatch Workers

For each resolved item, launch a worker. Route to the appropriate agent based on the task domain (see `AGENTS.md` "Agent Routing") and pick the execution mode:

```bash
# For code tasks (Build+ is default — omit --agent)
opencode run --dir ~/Git/<repo> --title "t083: <description>" \
  "/full-loop t083 -- <description>" &

# For code tasks in a specialist domain
opencode run --dir ~/Git/<repo> --agent SEO --title "t084: <description>" \
  "/full-loop t084 -- <description>" &

# For non-code operational tasks (no /full-loop)
opencode run --dir ~/Git/<repo> --agent SEO --title "Weekly rankings" \
  "/seo-export --account client-a --format summary" &

# For recurring operations, schedule this command via launchd/cron
# instead of queueing repeating TODO items

# For PRs
opencode run --dir ~/Git/<repo> --title "PR #382: <title>" \
  "/full-loop Fix PR #382 (https://github.com/user/repo/pull/382) -- <what needs fixing>" &

# For issues
opencode run --dir ~/Git/<repo> --title "Issue #42: <title>" \
  "/full-loop Implement issue #42 (https://github.com/user/repo/issues/42) -- <description>" &
```

**Dispatch rules:**
- Use `--dir ~/Git/<repo-name>` matching the repo the task belongs to
- Use `--agent <name>` to route to a specialist (SEO, Content, Marketing, etc.)
- Omit `--agent` for code tasks — defaults to Build+
- Use `/full-loop` only when the task needs repo code changes and PR traceability
- For non-code operations, run the task command directly (for example `/seo-export ...`)
- Do NOT add `--model` unless escalation is required by workflow policy
- **Background each dispatch with `&`** so multiple workers launch concurrently
- Code workers handle branch/PR lifecycle; ops workers execute and report outcomes

### Step 3: Monitor

After dispatching, show the user what was launched:

```text
## Dispatched Workers

| # | Item | Worker |
|---|------|--------|
| 1 | t083: Create Bing Webmaster Tools subagent | dispatched |
| 2 | t084: Create Rich Results Test subagent | dispatched |
| 3 | PR #382: Fix auth middleware | dispatched |
```

Workers are independent. They succeed or fail on their own. The next `/pulse` cycle
(or the user) can check on outcomes and dispatch follow-ups.

## Dispatcher Philosophy

The `/pulse` supervisor NEVER does task work itself:

- **Never** reads source code or implements features
- **Never** runs tests or linters on behalf of workers
- **Never** pushes branches or resolves merge conflicts for workers
- **Always** dispatches workers via `opencode run` with the command chosen by task type
- **Always** routes to the right agent — not every task is code

`/runners` is a targeted dispatch tool, not a supervisor. It dispatches exactly what you specify and stops. If a worker fails, improve the worker instructions/command definition, not the dispatcher. Each fixed failure improves the next run.

**Self-improvement:** The `/pulse` supervisor observes outcomes from GitHub state (PRs, issues, timelines) and files improvement issues for systemic problems. See `AGENTS.md` "Self-Improvement" for the universal principle. The supervisor never maintains separate state — TODO.md, PLANS.md, and GitHub are the database.

## Examples

All items in a single `/runners` invocation are dispatched concurrently — each becomes a separate `opencode run ... &` background process. They do not block each other.

```bash
# Dispatch specific tasks (all three launch concurrently)
/runners t083 t084 t085

# Fix specific PRs (both launch concurrently)
/runners #382 #383

# Work on a GitHub issue
/runners https://github.com/user/repo/issues/42

# Free-form task
/runners "Add rate limiting to the API endpoints"

# Multiple mixed items (all three launch concurrently)
/runners t083 #382 "Fix the login bug"
```
