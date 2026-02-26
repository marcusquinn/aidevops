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

See `pulse.md` for the full spec.

### Pulse Scheduler Setup

The pulse runs via a macOS launchd plist. If the plist doesn't exist (fresh install, new machine, or after a crash that deleted it), create it:

```bash
# 1. Get the opencode binary path and user PATH for the plist
which opencode        # e.g. /opt/homebrew/bin/opencode
echo "$PATH"          # needed for EnvironmentVariables

# 2. Create the plist
cat > ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.aidevops.aidevops-supervisor-pulse</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>-c</string>
		<string>pgrep -f 'Supervisor Pulse' &gt;/dev/null &amp;&amp; exit 0; OPENCODE_PATH run "/pulse" --dir AIDEVOPS_DIR -m anthropic/claude-sonnet-4-6 --title "Supervisor Pulse"</string>
	</array>
	<key>StartInterval</key>
	<integer>120</integer>
	<key>StandardOutPath</key>
	<string>HOME_DIR/.aidevops/logs/pulse.log</string>
	<key>StandardErrorPath</key>
	<string>HOME_DIR/.aidevops/logs/pulse.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>USER_PATH</string>
		<key>HOME</key>
		<string>HOME_DIR</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST

# 3. Replace placeholders with actual values
sed -i '' "s|OPENCODE_PATH|$(which opencode)|g" ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
sed -i '' "s|AIDEVOPS_DIR|$HOME/Git/aidevops|g" ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
sed -i '' "s|HOME_DIR|$HOME|g" ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
sed -i '' "s|USER_PATH|$PATH|g" ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist

# 4. Create log directory and load
mkdir -p ~/.aidevops/logs
launchctl load ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
```

**Key settings:**
- `RunAtLoad: true` — fires immediately on login/reboot (no waiting for first timer tick)
- `KeepAlive: false` — each pulse is a one-shot run, not a long-lived daemon
- `StartInterval: 120` — fires every 2 minutes
- The `pgrep` guard prevents overlapping pulses (if a previous pulse is still running, skip)

### Enable / Disable / Verify

```bash
# Enable automated pulse
launchctl load ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist

# Disable automated pulse
launchctl unload ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist

# Check if loaded
launchctl list | grep aidevops-supervisor-pulse

# Check recent output
tail -50 ~/.aidevops/logs/pulse.log
```

### After Reboot

The pulse auto-starts on login (`RunAtLoad: true`). Old workers don't survive reboot — the first pulse cycle sees 0 workers, 6 empty slots, and dispatches fresh work. No manual intervention needed.

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
