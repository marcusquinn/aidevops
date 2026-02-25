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

1. Counts running workers (max 6 concurrent)
2. Fetches open issues and PRs from managed repos via `gh`
3. Observes outcomes — files improvement issues for stuck/failed work
4. Uses AI (sonnet) to pick the highest-value items to fill available slots
5. Dispatches workers via `opencode run "/full-loop ..."`, routing to the right agent

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

For each resolved item, launch a worker. Route to the appropriate agent based on the task domain (see `AGENTS.md` "Agent Routing"):

```bash
# For code tasks (Build+ is default — omit --agent)
opencode run --dir ~/Git/<repo> --title "t083: <description>" \
  "/full-loop t083 -- <description>" &

# For domain-specific tasks (route to specialist agent)
opencode run --dir ~/Git/<repo> --agent SEO --title "t084: <description>" \
  "/full-loop t084 -- <description>" &

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
- Do NOT add `--model` — let `/full-loop` use its default (opus)
- **Background each dispatch with `&`** so multiple workers launch concurrently
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
- **Always** routes to the right agent — not every task is code

If a worker fails, the fix is to improve the worker's instructions (`/full-loop`),
not to do the work for it. Each failure that gets fixed makes the next run more reliable.

**Self-improvement:** The supervisor observes outcomes from GitHub state (PRs, issues, timelines) and files improvement issues for systemic problems. See `AGENTS.md` "Self-Improvement" for the universal principle. The supervisor never maintains separate state — TODO.md, PLANS.md, and GitHub are the database.

## Examples

```bash
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
