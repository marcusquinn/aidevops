# t19209: fix(terminal-blocker): trigger revisit starves holds beyond the first ~20 search hits

Issue: GH#39481

## What

`terminal-blocker-trigger-revisit.sh` never reaches most `external_trigger_pending` holds in a repository with many holds. Satisfied triggers therefore stay `status:blocked` until a human starts an interactive session to recount and close them. Make every hold get revisited: walk the candidates least-recently-checked first, and memoize ineligible hits so they stop consuming reads every pass.

## Why

Observed on one pulse runner, against a managed repository with 45 open issues that match the owner search `"Terminal blocker: reason=external_trigger_pending"`:

- The pulse stage `trigger_revisit` runs with a 72s timeout. That gives the helper a budget of about 50–62s per pass (`pulse-stage-timings.log`: 49–63s every pass, 15 passes over 20h).
- `_tbtr_repo` walks the refs in search "best match" order, which is stable from pass to pass. Every pass spends its reads on the same leading hits and hits the deadline at around position 12–20.
- Ineligible hits are re-read every pass and never recorded. These are inactive holds, holds of another reason class, and legacy observations. Each one costs an issue fetch plus a paginated comments fetch (about 2.3–2.8s measured).
- The runner's record directory had no record for 27 of the 45 holds. Since 2026-11-18, records were written only for hits at positions 20 or earlier.
- Concrete loss: one hold at position 21 had a trigger of "one day after PR X merged, then recount". That trigger was met for about 21h and the hold was never revisited. An interactive session had to verify the trigger and close the issue by hand.

## How

1. `_tbtr_issue`: after a successful read that proves the hit ineligible, write a memo record `{updated_at, next_at: now+interval, decision: "ineligible", checked_at}`. Ineligible means closed/`needs-maintainer-review`, no observation, another reason class, or hold inactive (rc 1). Transient fetch failures and rc 2 stay unrecorded.
2. Stamp `checked_at` on scheduled and ineligible records; decided records already carry `revisited_at`.
3. `_tbtr_repo` → `_tbtr_order_refs`: stable-sort the refs by `checked_at // revisited_at // 0`, oldest first.
4. `tbtr_next_due`: ignore `ineligible` memos.

### Files Scope

- `.agents/scripts/terminal-blocker-trigger-revisit.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`

## Verification

- `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh` passes.
- `shellcheck .agents/scripts/terminal-blocker-trigger-revisit.sh` is clean.
- After deploy, the runner's `~/.aidevops/logs/terminal-blocker-trigger-revisit/` holds a record for every search hit within a few passes.
