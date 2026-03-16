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

The supervisor handles dispatch. The worker command depends on the work type.

> **Note:** The previous bash supervisor implementation (`supervisor-helper.sh` and `supervisor/*.sh`) has been archived to `.agents/scripts/supervisor-archived/` for reference. All active orchestration now uses the AI-driven pulse model described here. Any references to the old paths in setup scripts, tests, or docs should be treated as stale — the archived scripts are not sourced or executed by the current system.

## Automated Mode: `/pulse`

For unattended operation, the `/pulse` command runs every 2 minutes via launchd. Its prime directive is **fill all available worker slots with the highest-value work**. Each pulse cycle:

1. Checks capacity: counts running workers against the configured max (default 6 concurrent)
2. Reads pre-fetched state: open PRs and issues across all managed repos via `gh`
3. Merges ready PRs (green CI + review gate passed) — free, no worker slot needed
4. Dispatches workers to fill all `AVAILABLE` slots (not just one): assigns issues, routes to the right agent, and backgrounds each `opencode run` with `&`
5. Enters a monitoring loop: sleeps 60s, re-checks capacity, backfills any freed slots immediately

The pulse never dispatches just one worker and stops — it fills every available slot and keeps them filled for the duration of the session (up to 60 minutes). See `scripts/commands/pulse.md` for the full spec.

### Pulse Scheduler Setup

The pulse scheduler runs every 2 minutes and dispatches workers. Setup depends on your OS.

#### macOS (launchd)

If the plist doesn't exist (fresh install, new machine, or after a crash that deleted it), create it:

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

#### Linux (cron)

One cron entry with a pgrep guard to prevent overlapping pulses:

```bash
mkdir -p ~/.aidevops/logs

# Add to crontab (every 2 minutes)
(crontab -l 2>/dev/null; echo "*/2 * * * * pgrep -f 'Supervisor Pulse' >/dev/null || $(which opencode) run \"/pulse\" --dir $HOME/Git/aidevops -m anthropic/claude-sonnet-4-6 --title \"Supervisor Pulse\" >> $HOME/.aidevops/logs/pulse.log 2>&1 # aidevops: supervisor-pulse") | crontab -
```

**Key settings:**
- `*/2 * * * *` — fires every 2 minutes
- `pgrep` guard prevents overlapping pulses (if a previous pulse is still running, skip)
- Uses full path to `opencode` since cron has a minimal `PATH`

### Enable / Disable / Verify

```bash
## macOS
# Enable
launchctl load ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
# Disable
launchctl unload ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
# Check
launchctl list | grep aidevops-supervisor-pulse

## Linux
# Check
crontab -l | grep supervisor-pulse
# Disable
crontab -l | grep -v 'supervisor-pulse' | crontab -
# Re-enable — run the install command above

# Both platforms — check recent output
tail -50 ~/.aidevops/logs/pulse.log
```

### After Reboot

**macOS:** The pulse auto-starts on login (`RunAtLoad: true`).

**Linux:** Cron runs automatically after reboot — no extra config needed.

Old workers don't survive reboot on either platform — the first pulse cycle sees 0 workers, 6 empty slots, and dispatches fresh work. No manual intervention needed.

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
- **ALWAYS use `headless-runtime-helper.sh run`** — never bare `opencode run`. The helper provides provider rotation, session persistence, backoff handling, and lifecycle reinforcement that bare dispatch lacks.
- Use `--dir ~/Git/<repo-name>` matching the repo the task belongs to
- Use `--agent <name>` to route to a specialist (SEO, Content, Marketing, etc.)
- Omit `--agent` for code tasks — defaults to Build+
- Use `/full-loop` only when the task needs repo code changes and PR traceability
- For non-code operations, run the task command directly (for example `/seo-export ...`)
- Do NOT add `--model` unless escalation is required by workflow policy
- **Background each dispatch with `&`** and `sleep 2` between dispatches to avoid thundering herd
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

## Supervisor Philosophy

The supervisor (whether `/pulse` or `/runners`) NEVER does task work itself:

- **Never** reads source code or implements features
- **Never** runs tests or linters on behalf of workers
- **Never** pushes branches or resolves merge conflicts for workers
- **Always** dispatches workers via `headless-runtime-helper.sh run` (never bare `opencode run`)
- **Always** routes to the right agent — not every task is code

If a worker fails, improve the worker instructions/command definition,
not the supervisor role. Each fixed failure improves the next run.

**Self-improvement:** The supervisor observes outcomes from GitHub state (PRs, issues, timelines) and files improvement issues for systemic problems. See `AGENTS.md` "Self-Improvement" for the universal principle. The supervisor never maintains separate state — TODO.md, PLANS.md, and GitHub are the database.

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
