<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Incident Recovery Runbook (t3001)

When the pulse silently degrades — workers killed at per-candidate timeout,
cycles taking 25+ minutes, `gh search` returning empty results — this is
the operator decision tree.

## Symptom checklist

You are likely looking at a GitHub-platform incident (not a framework bug)
when **two or more** of these are true:

- `tail -f ~/.aidevops/logs/pulse-wrapper.log` shows workers being killed
  with `rc=124` at exactly the per-candidate-timeout boundary (default 90s,
  configurable via `FILL_FLOOR_PER_CANDIDATE_TIMEOUT`).
- A pulse cycle takes >25 minutes to complete despite a recent restart.
- `gh search issues "..."` returns an empty list when issues you can see
  in the GitHub UI should match.
- `gh api rate_limit --jq .resources.search.remaining` is healthy
  (>5/30) but search operations still fail.
- `gh auth status` is fine; tokens are valid; nothing in your environment
  changed.

If only one of these is true and there's a recent code change in the
suspect path, treat it as a code bug first. If two or more, suspect a
GitHub-platform incident and confirm via the next section.

## Confirm via gh-status-helper

`gh-status-helper.sh check` is the canonical confirmation step:

```bash
gh-status-helper.sh check
# → operational | degraded | outage
# → exit 0 / 1 / 2

gh-status-helper.sh incidents
# → list of unresolved incidents with components and timestamps
```

The helper hits `https://www.githubstatus.com/api/v2/` with a 60-second
response cache (`~/.aidevops/cache/gh-status-*.json`) so repeated calls
during a tight diagnostic loop don't hammer the Statuspage API.

If `check` returns `operational` and you still see the symptoms above,
the issue is local — proceed to "Local recovery" below.

If `check` returns `degraded` or `outage`, your code is fine and you're
waiting on GitHub. Proceed to "Incident handling".

## Incident handling

While GitHub's Statuspage shows an active incident:

1. **Don't fight the platform.** Workers will keep dying at the
   per-candidate-timeout. Pulse cycles will keep timing out. There is no
   fix you can ship that resolves the upstream incident.

2. **Document the correlation on affected issues.** For each issue or PR
   that timed out during the incident window, post a correlation comment
   so future sessions don't waste tokens diagnosing the same symptom:

   ```bash
   # Capture the markdown block once
   gh-status-helper.sh correlate > /tmp/correlate.md
   gh-signature-helper.sh footer >> /tmp/correlate.md

   # Apply to each affected issue/PR
   gh issue comment <N> --repo <slug> --body-file /tmp/correlate.md
   ```

   The block carries an HTML marker (`<!-- aidevops:gh-status-correlation -->`)
   so retrospective scans can find every incident-impacted issue.

3. **Pause new dispatch.** If the pulse is still running and burning
   workers on doomed dispatches, stop it:

   ```bash
   pulse-lifecycle-helper.sh stop
   ```

   Restart only after `gh-status-helper.sh check` returns `operational`.

4. **Hand-dispatch only the urgent issues.** If a specific issue
   absolutely must move during the incident, use the manual single-issue
   dispatch helper (which now applies pulse-parity ceremony — see t3000
   below):

   ```bash
   dispatch-single-issue-helper.sh dispatch <N> <slug>
   ```

   This launches one worker without going through the pulse cycle.
   Workers spawn in isolated worktrees, so a failed run doesn't poison
   the next attempt.

## Local recovery

When `gh-status-helper.sh check` returns `operational` but symptoms
persist, the issue is local. The recurring causes:

### Stale ledger lock (t2999, PR #21428)

The dispatch ledger uses an `mkdir`-based lock at
`~/.aidevops/.agent-workspace/tmp/dispatch-ledger.lock`. When a worker
crashes mid-dispatch (or a previous shell exited abnormally), the lock
directory persists and silently blocks all subsequent
`_dsi_register_ledger` calls. Symptom: workers launch and run, but the
ledger never updates, so the pulse can't see what's in flight.

Recovery is automatic in deployed scripts — the t2999 fix adds
age-based force-reclaim. To check manually:

```bash
ls -la ~/.aidevops/.agent-workspace/tmp/dispatch-ledger.lock
# If older than 60 seconds and you're not running a worker, delete it:
rm -rf ~/.aidevops/.agent-workspace/tmp/dispatch-ledger.lock
```

See `pulse-lock-recovery.md` for the analogous pulse-instance lock and
its 30-minute force-reclaim ceiling.

### Stale interactive claim (zombie status:in-review)

If an issue is stuck in `status:in-review` with you as the assignee but
no live session is working on it, the claim is zombie. Pulse won't
dispatch a worker (claim is honoured); you need to release:

```bash
interactive-session-helper.sh scan-stale
# → reports zombie claims; auto-releases dead-PID stamps in TTY sessions

# Manual release for a specific issue:
interactive-session-helper.sh release <N> <slug>
```

### Pulse cycle stuck in cache-cold state

After a long quiet period or fresh `aidevops update`, the first pulse
cycle does a cold cache prime that can take ~3.5 minutes. This is
expected. If subsequent cycles are still slow:

```bash
# Check the prime sentinel
ls -la ~/.aidevops/cache/pulse-cache-prime-last-run

# Force a prime
rm -f ~/.aidevops/cache/pulse-cache-prime-last-run
pulse-lifecycle-helper.sh restart
```

t2992 + t2994 cover the prime mechanism in detail.

## Manual dispatch ceremony (t3000, PR #21430)

The single-issue dispatch helper (`dispatch-single-issue-helper.sh`)
applies pulse-parity label and assignee ceremony BEFORE launching the
worker. This closes the duplicate-dispatch race window observed during
the 2026-04-27 incident — without ceremony, the issue stays in its prior
state (typically `status:available` with no assignee) and the next pulse
cycle can re-dispatch a duplicate worker on top of the running one.

Default behaviour applies ceremony:

```bash
dispatch-single-issue-helper.sh dispatch <N> <slug>
# → atomic transition to status:queued
# → adds origin:worker; removes origin:interactive + origin:worker-takeover
# → adds you as assignee; removes any prior assignees
# → then launches the worker in a fresh worktree
```

Opt out for the rare debugging case:

```bash
dispatch-single-issue-helper.sh dispatch <N> <slug> --no-ceremony
```

`--no-ceremony` is for relaunching a worker without disturbing
label/assignee state — e.g. when investigating why a previous run died
and you want the issue to stay exactly as the dead worker left it.

Compose with `--dry-run` to preview the ceremony plan without acting.

## Post-incident verification

After the GitHub incident clears (`gh-status-helper.sh check` returns
`operational`), confirm normal operation before declaring recovery:

- [ ] `gh api rate_limit --jq '.resources | {core, graphql, search}'`
      shows healthy budgets (≥80% remaining for each pool).
- [ ] Pulse cycle time back to <5 minutes:
      `tail -50 ~/.aidevops/logs/pulse-wrapper.log | grep "cycle complete"`.
- [ ] Ledger health: no entries with `result:failed` in the last
      5 minutes that aren't accompanied by an obvious cause:
      `tail -200 ~/.aidevops/.agent-workspace/tmp/dispatch-ledger.jsonl | jq 'select(.result == "failed")'`.
- [ ] Downstream-repo dispatch resumed: `gh issue list --search
      "is:open status:in-progress" --repo <slug>` shows expected
      throughput.
- [ ] Correlation comments posted on every issue/PR that timed out
      during the incident window. `gh search issues "<!-- aidevops:gh-status-correlation -->"`
      finds all of them retrospectively.

## Audit trail

Every recovery step leaves evidence:

- `gh-status-helper.sh` cache files at `~/.aidevops/cache/gh-status-*.json`.
- Correlation comments on affected issues with the
  `<!-- aidevops:gh-status-correlation -->` marker.
- Ledger entries at `~/.aidevops/.agent-workspace/tmp/dispatch-ledger.jsonl`
  for every manual dispatch.
- Pulse log at `~/.aidevops/logs/pulse-wrapper.log` for cycle-level
  events.

## Related documents

- `reference/pulse-lock-recovery.md` — pulse-instance lock force-reclaim
- `reference/auto-dispatch.md` — dispatch dedup and the
  combined-signal rule
- `reference/worker-diagnostics.md` — worker lifecycle and recovery
- t2999 (PR #21428) — dispatch ledger stale lock recovery
- t3000 (PR #21430) — manual dispatch pulse-parity ceremony
- t3001 (this runbook + `gh-status-helper.sh`)
