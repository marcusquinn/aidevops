# t1367: Add struggle-ratio metric to pulse stuck-detection

## Origin

- **Created:** 2026-03-01
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (user-requested)
- **Conversation context:** Same devsql analysis session as t1366. DevSQL's "struggle ratio" concept (`prompts / commits = struggle_ratio`) identifies sessions where the agent was active but unproductive. Our current stuck detection uses wall-clock time (3+ hours with no PR), which misses "active but thrashing" workers. This metric fills that gap.

## What

Add a `struggle_ratio` metric to the supervisor pulse's worker health checks. For each active worker session:

1. **Count messages**: number of user/assistant message exchanges in the session
2. **Count commits**: `git log` entries in the worker's worktree since the session started
3. **Compute ratio**: `messages / max(1, commits)` — high ratio = thrashing
4. **Flag threshold**: if ratio exceeds a configurable threshold (default: 30 messages per commit) AND the session has been running for >30 minutes, flag as "struggling"

## Why

Current stuck detection has a blind spot: workers that are actively sending messages but producing no useful output. These consume model tokens and worker slots without progress. The wall-clock timeout (3h) catches completely stuck workers, but a worker that sends 200 messages over 2 hours with zero commits is clearly thrashing and should be flagged earlier.

This was inspired by devsql's "struggle session" query:
```sql
SELECT prompts, commits, CAST(prompts AS FLOAT) / MAX(1, commits) as struggle_ratio
```

The metric is cheap to compute (one `git log --oneline | wc -l` per worker) and complements existing health checks.

## How (Approach)

### Files to modify

- `.agents/scripts/commands/pulse.md` — Add struggle-ratio check to worker health section
- `.agents/scripts/session-miner-pulse.sh` — Optionally compute struggle ratio in post-session analysis too

### Implementation

1. **In pulse worker health checks** (the section that checks `ps axo pid,etime,command`):
   - For each running worker, identify its worktree path from the `--dir` argument
   - Count commits since worker start: `git -C <worktree> log --oneline --since=<start_time> | wc -l`
   - Estimate message count from session size or OpenCode API if available (fallback: use elapsed time * average messages/hour heuristic)
   - Compute `struggle_ratio = estimated_messages / max(1, commits)`

2. **Threshold and action**:
   - `struggle_ratio > 30` AND `elapsed > 30min` AND `commits == 0`: flag as "struggling — no commits"
   - `struggle_ratio > 50` AND `elapsed > 60min`: flag as "thrashing — consider killing"
   - Log the ratio in pulse output for all workers (informational)
   - Do NOT auto-kill — flag for supervisor decision (the LLM reasoning phase can decide)

3. **Configuration**:
   - `STRUGGLE_RATIO_THRESHOLD` env var (default: 30)
   - `STRUGGLE_MIN_ELAPSED_MINUTES` env var (default: 30)

### Edge cases

- Workers with no `--dir` argument: skip (can't check git)
- Workers on repos with no commits yet (new repo): skip ratio check
- Workers doing research/planning (legitimately high message count, low commits): the 30-min minimum elapsed time and the supervisor LLM reasoning phase handle this — the metric is a signal, not an auto-kill trigger

## Acceptance Criteria

1. Pulse output includes `struggle_ratio` for each active worker that has a worktree
2. Workers exceeding the threshold are flagged in pulse output with a clear message
3. The flag is informational — no auto-kill, supervisor LLM decides action
4. Configurable thresholds via environment variables
5. Workers without worktrees or on new repos are gracefully skipped

## Estimates

- **Effort:** ~2h
- **Model tier:** sonnet
- **Risk:** Low — additive check in pulse, no changes to worker behaviour
