---
description: Dispatch workers for tasks, PRs, or issues via opencode run
agent: Build+
mode: subagent
---

Dispatch one or more workers to handle tasks. Each worker runs `/full-loop` in its own session.

Arguments: $ARGUMENTS

## How It Works

The runners system is intentionally simple:

1. **You tell it what to work on** (task IDs, PR numbers, issue URLs, or descriptions)
2. **It dispatches `opencode run "/full-loop ..."` for each item** — one worker per task
3. **Each worker handles everything end-to-end** — branching, implementation, PR, CI, merge, deploy
4. **No databases, no state machines, no complex bash pipelines**

The `/full-loop` command is the worker. It already works. Runners just launches it.

## Automated Mode: `/pulse`

For unattended operation, the `/pulse` command runs every 2 minutes via launchd. It:

1. Checks if a worker is already running (if yes, skips)
2. Fetches open issues and PRs from managed repos via `gh`
3. Uses AI (sonnet) to pick the single highest-value thing to work on
4. Dispatches one worker via `opencode run "/full-loop ..."`

See `pulse.md` for the full spec. Enable/disable with:

```bash
# Enable automated pulse (every 2 minutes)
launchctl load ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist

# Disable automated pulse
launchctl unload ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist

# Check if running
launchctl list | grep aidevops-supervisor-pulse
```

## Interactive Mode: `/runners`

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

For each resolved item, launch a worker:

```bash
# For tasks
opencode run --dir ~/Git/<repo> --title "t083: <description>" \
  "/full-loop t083 -- <description>"

# For PRs
opencode run --dir ~/Git/<repo> --title "PR #382: <title>" \
  "/full-loop Fix PR #382 (https://github.com/user/repo/pull/382) -- <what needs fixing>"

# For issues
opencode run --dir ~/Git/<repo> --title "Issue #42: <title>" \
  "/full-loop Implement issue #42 (https://github.com/user/repo/issues/42) -- <description>"
```

**Dispatch rules:**
- Use `--dir ~/Git/aidevops` for aidevops repo work
- Use `--dir ~/Git/awardsapp` for awardsapp repo work
- Do NOT add `--model` — let `/full-loop` use its default (opus)
- Workers handle everything: branching, implementation, PR, CI, merge, deploy

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

## Supervisor Philosophy

The supervisor (whether `/pulse` or `/runners`) NEVER does task work itself:

- **Never** reads source code or implements features
- **Never** runs tests or linters on behalf of workers
- **Never** pushes branches or resolves merge conflicts for workers
- **Always** dispatches workers via `opencode run "/full-loop ..."`

If a worker fails, the fix is to improve the worker's instructions (`/full-loop`),
not to do the work for it. Each failure that gets fixed makes the next run more reliable.

## Examples

```bash
# Dispatch specific tasks
/runners t083 t084 t085

# Fix specific PRs
/runners #382 #383

# Work on a GitHub issue
/runners https://github.com/awardsapp/awardsapp/issues/42

# Free-form task
/runners "Add rate limiting to the API endpoints"

# Multiple mixed items
/runners t083 #382 "Fix the login bug"
```
