---
description: Dispatch workers for tasks, PRs, or issues via opencode run
agent: Build+
mode: subagent
---

Dispatch one or more workers to handle tasks. Pick the execution mode per task type:

- **Code-change work** (repo edits, tests, PRs) -> `/full-loop`
- **Operational work** (reports, audits, monitoring, outreach) -> direct command execution (no PR ceremony)

Arguments: $ARGUMENTS

## Scope Boundary

**`/runners` is a targeted dispatch tool, not a supervisor.**

When invoked as `/runners GH#267 GH#268` (or any explicit list of items), it does exactly this:

1. Resolve the specified items
2. Dispatch one worker per item
3. Show the dispatch table
4. Stop

It does **NOT**:

- Run supervisor phases
- Perform auto-pickup of unrelated tasks
- Run stale claim recovery
- Run phantom queue reconciliation
- Run AI lifecycle evaluation
- Run CodeRabbit pulse
- Run audit checks
- Fill worker slots beyond the explicitly specified items

For unattended operation that fills all available slots and runs supervisor phases, use `/pulse`. See `.agents/scripts/commands/pulse.md`.

## How It Works

The runners system is intentionally simple:

1. **You tell it what to work on** (task IDs, PR numbers, issue URLs, or descriptions)
2. **It dispatches `opencode run` for each item** — one worker per task
3. **Code workers** handle branch -> implementation -> PR -> CI -> merge
4. **Ops workers** execute the requested SOP/command and report outcomes
5. **No databases, no state machines, no complex bash pipelines**

## Interactive Mode: `/runners`

**Scope boundary:** When invoked as `/runners`, ONLY resolve and dispatch the items explicitly specified in the arguments. Do NOT:

- Run supervisor phases
- Auto-pickup additional tasks
- Perform lifecycle evaluation
- Run quality sweeps
- Trigger a CodeRabbit pulse

Dispatch exactly the requested items and stop.

For manual dispatch of specific work items.

### Input Types

| Pattern | Type | Example |
|---------|------|---------|
| `GH#\d+` | GitHub issue/PR numbers | `/runners GH#267 GH#268` |
| `t\d+` | Task IDs from TODO.md | `/runners t083 t084 t085` |
| `#\d+` or PR URL | PR numbers | `/runners #382 #383` |
| Issue URL | GitHub issue | `/runners https://github.com/user/repo/issues/42` |
| Free text | Description | `/runners "Fix the login bug"` |

### Step 1: Resolve What to Work On

For each input item, resolve it to a description:

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

### Step 2: Dispatch Workers

For each resolved item, launch a worker using `headless-runtime-helper.sh run`. This is the **ONLY** correct dispatch path — it constructs the full lifecycle prompt, handles provider rotation, session persistence, and backoff. NEVER use bare `opencode run` for dispatch — workers launched that way miss lifecycle reinforcement and stop after PR creation (see GH#5096).

```bash
HELPER="$(aidevops config get paths.agents_dir)/scripts/headless-runtime-helper.sh"

# For code tasks (Build+ is default — omit --agent)
$HELPER run \
  --role worker \
  --session-key "task-t083" \
  --dir ~/Git/<repo> \
  --title "t083: <description>" \
  --prompt "/full-loop t083 -- <description>" &
sleep 2

# For code tasks in a specialist domain
$HELPER run \
  --role worker \
  --session-key "task-t084" \
  --dir ~/Git/<repo> \
  --agent SEO \
  --title "t084: <description>" \
  --prompt "/full-loop t084 -- <description>" &
sleep 2

# For non-code operational tasks (no /full-loop)
$HELPER run \
  --role worker \
  --session-key "seo-weekly" \
  --dir ~/Git/<repo> \
  --agent SEO \
  --title "Weekly rankings" \
  --prompt "/seo-export --account client-a --format summary" &
sleep 2

# For PRs
$HELPER run \
  --role worker \
  --session-key "pr-382" \
  --dir ~/Git/<repo> \
  --title "PR #382: <title>" \
  --prompt "/full-loop Fix PR #382 (https://github.com/user/repo/pull/382) -- <what needs fixing>" &
sleep 2

# For issues
$HELPER run \
  --role worker \
  --session-key "issue-42" \
  --dir ~/Git/<repo> \
  --title "Issue #42: <title>" \
  --prompt "/full-loop Implement issue #42 (https://github.com/user/repo/issues/42) -- <description>" &
sleep 2
```

**Dispatch rules:**

- Use `--dir ~/Git/<repo-name>` matching the repo the task belongs to
- Use `--agent <name>` to route to a specialist (SEO, Content, Marketing, etc.)
- Omit `--agent` for code tasks — defaults to Build+
- Use `/full-loop` only when the task needs repo code changes and PR traceability
- For non-code operations, run the task command directly (for example `/seo-export ...`)
- Do NOT add `--model` unless escalation is required by workflow policy
- **Background each dispatch with `&`** and `sleep 2` between dispatches to avoid thundering herd
- Code workers handle branch/PR lifecycle; ops workers execute and report outcomes

### Step 3: Show Dispatch Table

After dispatching, show the user what was launched:

```text
## Dispatched Workers

| # | Item | Worker |
|---|------|--------|
| 1 | GH#267: <title> | dispatched |
| 2 | GH#268: <title> | dispatched |
```

Then stop. Workers are independent — they succeed or fail on their own. The next `/pulse` cycle (or the user) can check on outcomes and dispatch follow-ups.

## Dispatch Philosophy

`/runners` dispatches workers. It does not supervise them.

- **Never** reads source code or implements features
- **Never** runs tests or linters on behalf of workers
- **Never** pushes branches or resolves merge conflicts for workers
- **Always** dispatches workers via `headless-runtime-helper.sh run` (never bare `opencode run`)
- **Always** routes to the right agent — not every task is code
- **Always** stops after dispatching the explicitly specified items

`/runners` is a targeted dispatch tool, not a supervisor. It dispatches exactly what you specify and stops.

If a worker fails (whether dispatched by `/pulse` or `/runners`), improve the worker's instructions or command definition, not the dispatcher's role. Each fixed failure improves the next run.

## Examples

All items in a single `/runners` invocation are dispatched concurrently — each becomes a separate `opencode run ... &` background process. They do not block each other.

```bash
# Dispatch specific GitHub issues (both launch concurrently, then stop)
/runners GH#267 GH#268

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
