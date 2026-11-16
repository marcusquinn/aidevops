## What

A changed repository recovery policy ends the 24-hour suppression of a recorded `human_decision`, so the Pulse recovery supervisor re-assesses those issues on its next pass with the authority the maintainer just delegated.

## Why

`_tbr_decision_active` in `.agents/scripts/terminal-blocker-recovery-helper.sh` suppresses re-assessment of a recorded decision for `BLOCKER_RECOVERY_DECISION_TTL` (default 86400 s). It ends early only when a maintainer replies (GH#38311). When a repository restores, adds or changes its recovery policy, decisions recorded as `human_decision` *because no delegated authority existed* stay parked for up to a day, and are only reconsidered on the next 3-hour supervisor slot after that.

Observed: a managed private repository lost its policy when `.aidevops.json` became untracked (the t19065 migration case); the supervisor recorded 40 `human_decision` outcomes there (25 on 2026-11-16 alone), most of them routine outlier/source choices that the repo's `outlier_hold` / `session_cap_split` actions delegate. One decision says so explicitly: "Maintainer authorizes the factory split ..., or enables session_cap_split in the repo default-branch recovery policy; no delegated policy exists for this runner". Restoring the policy at the conventional location does not wake them.

## How

- `tbr_record`: for `wake == human_decision`, stamp `policy_fingerprint`: a hash of the policy's normalized `.actions` JSON (`jq -S -c`), or `none` when `recovery-policy-helper.sh` exits 3. On a failed observation, omit the field. Reuse `_terminal_blocker_hash` (`.agents/scripts/terminal-blocker-circuit.sh:142`); source that file lazily, as other functions in the helper already do.
- Fingerprint the actions, not `revision`: `revision` is the default-branch commit SHA and changes on every commit, which would cancel every suppression on each merge.
- One per-process cached loader feeds both `_tbr_policy_enabled` (unchanged contract: 0 enabled, 1 absent/empty, 2 unreadable) and the fingerprint, so a pass loads each repo's policy at most once.
- `_tbr_decision_active`: for `human_decision` within the TTL, when the current fingerprint is readable and differs from the recorded one, return 1 (not active). Treat a missing recorded field (legacy records) as `none`, so repos without a policy are unaffected and a newly restored policy wakes legacy decisions once. Unreadable current policy keeps suppression (fail closed on observation, as today).
- Document the rule in the helper header and `reference/recovery-policy.md`.

## Acceptance

- A `human_decision` recorded with fingerprint `none` stops suppressing once a policy with actions loads; the same record keeps suppressing while the policy stays absent or unreadable.
- A record stamped with the current fingerprint keeps suppressing until the TTL or a maintainer reply, as today.
- Non-`human_decision` wakes are unaffected.
- `bash .agents/scripts/tests/test-terminal-blocker-circuit-discovery.sh` and `bash .agents/scripts/tests/test-recovery-policy.sh` pass; ShellCheck clean.

## Files to modify

- EDIT `.agents/scripts/terminal-blocker-recovery-helper.sh` (`_tbr_policy_enabled`, `_tbr_decision_active`, `tbr_record`, header)
- EDIT `.agents/reference/recovery-policy.md`
- EDIT `.agents/scripts/tests/test-terminal-blocker-circuit-discovery.sh` (decision-active cases near line 759)

### Files Scope

- `.agents/scripts/terminal-blocker-recovery-helper.sh`
- `.agents/reference/recovery-policy.md`
- `.agents/scripts/tests/test-terminal-blocker-circuit-discovery.sh`
