## What

`tbr_pending` (`.agents/scripts/terminal-blocker-recovery-helper.sh`, per-tier scan in `_tbr_pending_scan_tier`) scans tier 0 (entries without a standing `human_decision`) through a full rotation before tier 1 (decided entries) starts (GH#38692). Both tiers share one queue deadline. When tier 0 cannot finish inside the deadline, tier 1 is never scanned.

On this runner it has never been scanned in either mode. `pending_cursor_decided` and `rearm_cursor_decided` do not exist in `~/.aidevops/.agent-workspace/terminal-blocker-recovery/`, although `_tbr_pending_scan_tier` saves the tier cursor before every entry check. `pending_cursor` and `rearm_cursor` were written minutes ago. The queue holds ~125 entries (~78 undecided). The pending queue window is ~29s (45s budget minus a 16s seed/unclassified reserve), and the rearm window is 45s.

Fix: reserve a share of the queue window for tier 1 whenever decided entries exist. Tier 0 stops at its own deadline (queue deadline minus the reserve, with the reserve at about a quarter of the remaining window and at least 1s), and tier 1 then runs until the queue deadline. Tier 1 gets any time tier 0 leaves unused. Classify the queue once per run, instead of calling `_tbr_entry_decided` (3 jq reads) for every file in every tier and pass.

## Why

Tier 1 is where every positive wake signal for a decided hold lives:

- A maintainer reply newer than the decision (GH#38311).
- A changed repo recovery policy (t19068).
- In rearm mode, a trusted `terminal-blocker-circuit:retry` or a brief revision.

None of these can fire while tier 1 is never scanned. A maintainer who answers a decision packet gets no action, and the issue stays blocked until someone starts an interactive session. Current example: 14 `human_decision` records in one managed repo carry no policy fingerprint. That repo now declares `session_cap_split` and `brief_authority`, so t19068 should wake them for re-assessment. None has been re-assessed.

## How

- EDIT `.agents/scripts/terminal-blocker-recovery-helper.sh`:
  - New `_tbr_pending_classify`, run once before the tier loop: it builds the decided set from `_tbr_entry_decided` and sets a tier-0 deadline when the set is non-empty.
  - `_tbr_pending_scan_tier` takes tier membership from that set and uses the tier-0 deadline for tier 0. Hitting the tier-0 deadline marks the run incomplete and returns a distinct code, so the caller continues to tier 1. Hitting the queue deadline still stops both tiers.
  - Keep `tbr_pending` and the new functions under 100 lines each.

### Files Scope

- .agents/scripts/terminal-blocker-recovery-helper.sh

## Acceptance Criteria

- [ ] With decided entries queued and a window too small for tier 0, a `pending` run checks at least one tier-1 entry and writes `pending_cursor_decided`. The same holds for `rearm` and `rearm_cursor_decided`.
- [ ] With no decided entries, tier 0 keeps the whole queue window.
- [ ] The GH#39006 `--count` cursor hold behaves the same in both tiers.
- [ ] `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh` passes; ShellCheck clean.

## Verification

- `shellcheck .agents/scripts/terminal-blocker-recovery-helper.sh`
- `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh`
- After deploy: `pending_cursor_decided` and `rearm_cursor_decided` appear in the recovery root within one pulse cycle, and decided records without a policy fingerprint in a repo that now has a policy get re-recorded with one.
