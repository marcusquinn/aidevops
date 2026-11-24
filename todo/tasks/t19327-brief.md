## What

Make the supervisor `pending` pass (and its `--count` trigger probe) skip decided queue entries that have not changed since their decision after one issue read, instead of reading comments and computing the brief revision for each one. Today a 45 s pass observes about 3 of 131 queued entries, so the LLM recovery supervisor rarely sees the holds that are actually due, and blocked issues wait days for an AI owner.

## Why

Evidence from one runner (2026-11-24, `~/.aidevops/.agent-workspace/terminal-blocker-recovery`; one managed product repo holds most entries):

- 131 queue entries; in the main repo 67 of 118 have a recorded decision.
- The latest trigger probe (`supervisor/last_blocker_recovery_probe.err`, 00:02Z) checked **3 entries** in its 45 s budget. One hit the 8 s stage cap (`incomplete stage=entry rc=124`), and the pass ended `incomplete stage=queue reason=unobserved_entries`.
- `gh-api-calls.log` for that probe shows 3–4 REST/GraphQL calls per entry (issue, comments, revision/timeline), about 0.6–2.6 s each through the wrapper, so 8–11 s per entry. The 45 s budget is fixed by the 120 s supervisor shell timeout (GH#35290), and the queue window is about 29 s of it.
- A recovery-policy edit (2026-11-23T04:17Z) woke 41 decided entries by design (t19068). About 21 h later only 6 had been re-assessed.
- `trigger=blocker_recovery` supervisor runs: 11-22 05:13, 09:54, 15:49; 11-23 17:02 (17 h after the previous cycle); 11-24 00:05. The probe only triggers a run when its small window happens to contain a due entry. Most windows contain only standing decided entries, which still cost the full 3–4 reads each before the decision check at the end of `_tbr_check_entry`.

For a decided entry whose decision is still active by time and policy, the only remaining wake is a reply newer than the decision, and any comment advances the issue's `updated_at`. Releases from a trusted retry, brief revision, dependency closure or permission window belong to the mechanical `rearm` pass (every `PULSE_BLOCKER_REARM_INTERVAL`, 600 s), which runs the same release code. Reading comments for an unchanged decided entry in the supervisor pass therefore cannot change its outcome.

## How

1. `.agents/scripts/terminal-blocker-recovery-helper.sh` `_tbr_check_entry`: for the normal intake path (after `_tbr_check_intake_entry` returns 3), in non-rearm mode (supervisor `pending` and `--count`), right after the issue read: if a decision file exists, `_tbr_decision_active "$key"` (no comments, so only the time/TTL and policy checks) succeeds, and the issue `updated_at` is not later than the decision's `recorded_epoch` (compare as epoch via jq `fromdateiso8601`; a missing or unparsable value never skips), return 1 without the comments and revision reads. Log one stage line (`blocker-recovery: decided_unchanged repo=… issue=…`) for diagnosis.
2. Do not change the rearm pass, release logic, intake routing (`unclassified_hold`, `answered_hold`, `unexplained_hold`, `persistent_exclusion`, `policy_remote`), or the tier split in `terminal-blocker-recovery-pending.sh`.
3. `.agents/reference/worker-integration-recovery.md` "Terminal-blocker recovery": one sentence noting that the supervisor pass skips unchanged decided entries after the issue read, and that the rearm pass owns mechanical releases.

Reference pattern: `_tbr_skip_unchanged_entry` in `.agents/scripts/terminal-blocker-recovery-release.sh` (the rearm-mode equivalent keyed on `rearm_checked_updated_at`).

### Files Scope

- `.agents/scripts/terminal-blocker-recovery-helper.sh`
- `.agents/reference/worker-integration-recovery.md`

## Acceptance

- A decided entry with an active decision and `updated_at` not after `recorded_epoch` is skipped after one issue read in `pending` and `pending --count`. It is still fully checked when `updated_at` is newer, when the decision is time-due or policy-changed, or in rearm mode.
- Runtime: with `AIDEVOPS_BLOCKER_RECOVERY_DIR` pointing to a copy of a real recovery store, `terminal-blocker-recovery-helper.sh pending --count` observes at least 3x more entries per 45 s call than before (compare `checking stage=entry_issue` counts on stderr). The copy must not be the live store, because `pending` moves cursors.
- `shellcheck -x` clean; `tests/test-recovery-policy.sh`, `tests/test-terminal-blocker-circuit-discovery.sh`, `tests/test-terminal-blocker-circuit-rearm.sh` and `tests/test-terminal-blocker-circuit.sh` pass.

## Not in scope

Running the synchronous LLM supervisor outside the pulse instance lock (GH#40112 / t19324 covers dispatch during maintenance stages) and batching issue reads per repository. File a follow-up if the 3x target is missed.
