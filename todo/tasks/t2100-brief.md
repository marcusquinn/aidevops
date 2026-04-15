<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2100: Harden ratchet-down pipeline and add pre-dispatch no-op validator (parent)

## Origin

- **Created:** 2026-04-15
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none — this IS the parent
- **Conversation context:** Triage of #19024 revealed that the pulse's ratchet-down issue generator filed a duplicate 2 minutes after the identical change (NESTING_DEPTH_THRESHOLD 284→279) had already landed in PR #19017, and the dispatched sonnet worker silently exited without closing the issue despite the "Worker triage responsibility" prompt rule. User asked for a systemic fix.

## What

Three-phase hardening of the ratchet-down pipeline plus a generalisable defense-in-depth layer:

1. **t2101 (#19036)** — Widen the dedup search window in `pulse-simplification.sh:1694-1698` to match PRs merged within the last 24h, not just open PRs. This closes the immediate duplicate-filing race.
2. **t2102 (#19037)** — Pull `$aidevops_path` fresh before running `complexity-scan-helper.sh ratchet-check` so the proposal reflects current main. Secondary cause of the #19024 duplicate.
3. **t2103 (#19038)** — New `pre-dispatch-validator-helper.sh` mechanism that runs an issue's own verification in a fresh checkout before the pulse spawns a worker. If the premise has been falsified (thresholds already tight, stale at dispatch time), close the issue with a rationale comment instead of burning a dispatch cycle. First concrete validator: ratchet-down.

## Why

The `#19024` incident cost a worker dispatch, a re-triage by a human, and the #19024 worker's silent exit left the issue stuck in `status:queued` — the pulse would have re-dispatched it indefinitely. Two failures compound: (a) generator filed a stale proposal, (b) worker ignored the triage prompt. Fix 1+2 eliminate the generator bug; Fix 3 is the deterministic safety net that doesn't rely on models following prompts.

## Parent task

This issue has the `parent-task` label and is `#parent` tagged. It blocks dispatch unconditionally and exists only as a tracker. Implementation happens on the three children.

## Reference

- Incident: #19024 (closed as premise falsified)
- Prior related fix: t2089 / PR #18959 (this is its symmetric completion)
- Full detail: issue body of #19035 has the complete root-cause analysis, strategy, and acceptance criteria
- Triage evidence: https://github.com/marcusquinn/aidevops/issues/19024#issuecomment-4248172074

## Acceptance

- Children #19036, #19037, #19038 all merged
- No regression in t2089 keyword-search dedup
- Documentation for the new pre-dispatch validator mechanism
- Smoke test confirms duplicate ratchet-down issues can no longer be filed under the stale-read race
