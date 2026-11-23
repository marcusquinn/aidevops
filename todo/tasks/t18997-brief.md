<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Discovery pass: no wake path exists for a maintainer answer on a `hold-for-review` issue. Dispatch (`dispatch-dedup-assignment.sh` `_is_assigned_check_hold_for_review`), terminal-blocker recovery (`_TBR_OTHER_HOLDS_JQ`) and unclassified intake (GH#37978) all exclude the label; `_health_aged_hold_section` (GH#36788) only displays it.
- [x] Tier: `tier:thinking`. This changes a maintainer-trust boundary: which comments the recovery supervisor may carry out.

## What

Let a maintainer settle a held issue with a plain reply on that issue, and let pulse carry out the reply without an interactive session:

1. **Maintainer reply on a `hold-for-review` issue**: queue it for the runner-local AI recovery supervisor (new intake `answered_hold`), which carries out exactly what the reply decides and posts one receipt.
2. **`hold-for-review` with no stated reason** (no trusted comment around or after the label for a day): queue it for the runner that applied the label (intake `unexplained_hold`). That supervisor posts one decision packet, or a pointer to the issue that holds the decision. A blocked label is not an instruction, so it still needs a why.
3. **Maintainer reply after a recorded `human_decision`** (any terminal-blocker recovery intake): end the 24h decision suppression early so the owning supervisor re-assesses on its next pass instead of the next day.
4. **Supervisor dashboard**: show the ask from the newest trusted decision comment even when it does not use the exact words "Recommended path", and tell the maintainer that a reply on the issue is enough.

## Why

- `.agents/reference/worker-discipline.md:34` stated it directly: "nothing lifts that label when the answer arrives". Today the only way to act on a hold is an interactive session. That spends the maintainer's scarcest resource twice: once to decide and once to have the decision carried out.
- Evidence from 2026-11-14, one supervisor runner and one managed repo: the dashboard reported 47 maintainer-decision holds older than 3 days. All 10 visible rows said "No decision comment yet", although the issues did carry decision comments (`**Owner/action:**`, `**Unblock evidence:**`, pointers to the deciding issue). Of 57 open holds, 53 had no comment containing "Recommended path", and 10 had no trusted comment at all. Every post-hold maintainer comment was an interactive-session note.
- On this runner, 46 of 75 terminal-blocker recovery decisions were `wake: human_decision`. Each one suppressed re-assessment for 24h, even after the maintainer answered.

## How

1. New sourced module `.agents/scripts/terminal-blocker-recovery-holds.sh`, stage `holds` run from `tbr_pending` after seed and before the unclassified stage, in the supervisor pass only, never `rearm`. For each pulse repo, at most every `BLOCKER_RECOVERY_HOLD_INTERVAL` (default 3600s): list open `hold-for-review` issues (GraphQL), skip trust-gate and claim labels, skip unchanged issues by an `updatedAt|due|handled` memo, then read label events and comments.
   - `answered_hold`: this runner's own OWNER/MEMBER login commented after the latest hold label, with no signature footer, automation marker, trusted `<!-- aidevops:hold-reply:<id> -->` receipt or handled memo.
   - `unexplained_hold`: this runner's login applied the label more than `BLOCKER_RECOVERY_HOLD_EXPLAIN_AGE` (default 86400s) ago and no trusted non-notice comment exists from one hour before the label onward.
   - The stage writes nothing to GitHub.
2. `_tbr_check_hold_entry`: retire when the hold or its intake no longer matches, or once a decision is recorded after queueing (then memo the reply id). Print the usual JSON line with `reply_comment_id` and no local excerpts.
3. `_tbr_decision_active`: a recorded `human_decision` is inactive when a plain OWNER/MEMBER (or self) comment is newer than `recorded_epoch`.
4. Supervisor prompt (`pulse-wrapper-cycle.sh`) and `worker-discipline.md` "Maintainer replies on held issues": carry out exactly what the reply decides (revise/resume, retire, keep holding, answer once, or record a non-decision notice), post one receipt for public outcomes, record the decision; post a decision packet for `unexplained_hold`.
5. Dashboard: `_health_hold_recommendation` reads `Recommended path`, `Decision needed`, `Specific question`, `Owner/action`, `Owner/next action`, `Next action` and decision pointers; `_health_aged_hold_section` says a reply on the issue is enough.

### Files Scope

- `.agents/scripts/terminal-blocker-recovery-holds.sh`
- `.agents/scripts/terminal-blocker-recovery-helper.sh`
- `.agents/scripts/pulse-wrapper-cycle.sh`
- `.agents/scripts/stats-health-dashboard-issue.sh`
- `.agents/reference/worker-discipline.md`
- `.agents/scripts/tests/test-terminal-blocker-circuit-discovery.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`
- `.agents/scripts/tests/test-health-dashboard-identity-aliases.sh`

## Acceptance

- An unsigned own-login OWNER/MEMBER reply after the hold label is queued as `answered_hold` with its comment id. Not queued: a signed or `origin:worker` comment, another login's comment, a collaborator-association own-login comment, a comment before the hold label, a reply with a trusted receipt, an issue with `status:claimed` or `needs-maintainer-review`.
- A hold this runner applied more than a day ago, with no trusted comment from an hour before the label onward, is queued as `unexplained_hold`; not when another login applied it or a comment explains it.
- `rearm` never lists, reads or queues holds. The stage performs no GitHub write.
- A recorded decision retires the entry; the same reply is not queued again; a newer reply is.
- A maintainer reply newer than a recorded `human_decision` makes `_tbr_decision_active` false; a signed or older comment does not.
- The dashboard row shows `Owner/action` text and `Decision on #N`; "Recommended path" extraction still works.
- ShellCheck is clean; the terminal-blocker and dashboard suites pass.

## Verification

```bash
bash .agents/scripts/tests/test-terminal-blocker-circuit.sh
bash .agents/scripts/tests/test-health-dashboard-identity-aliases.sh
shellcheck -x .agents/scripts/terminal-blocker-recovery-holds.sh .agents/scripts/terminal-blocker-recovery-helper.sh .agents/scripts/stats-health-dashboard-issue.sh
```
