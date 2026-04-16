<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2144: Investigate issue-consolidation cascade reported in GH#19255

## Origin

- **Created:** 2026-04-16
- **Session:** opencode:interactive
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** n/a
- **Conversation context:** Follow-up from review of #19255. The reporter observed a real cascade (parent #961 triggered children #973/#974/#976) but attributed it to a mechanism (unset consolidation vars) that cannot produce that cascade in current mainline code. Phase 1 (#19343) hardens the defensive gap they cited; Phase 2 (#19346) centralizes defaults; this task investigates the actual cascade root cause once repro data is available.

## What

Identify the real mechanism behind the observed cascade. Require repro data from the reporter before dispatching any investigation worker. Produce: root-cause analysis with log evidence, a fix design, and a regression test that would catch the cascade in isolation. The fix itself may spawn child implementation task(s) or land directly depending on complexity.

## Why

The cascade is a real symptom in the reporter's environment. Multiple consolidation children dispatched rapidly off a single parent means one of:

1. Dedup race (`_consolidation_child_exists` + child creation not atomic)
2. Label ping-pong (`_reevaluate_consolidation_labels` clearing + re-setting)
3. Comment-filter leak (operational comments being counted as substantive)
4. Multiple pulse runners with insufficient instance-lock coordination
5. Reporter env drift (custom `THRESHOLD=1` or similar)

Phase 1's defensive fix does NOT resolve this — it addresses a theoretical failure that couldn't produce the observation. Distinguishing symptom from cause is the whole point of this task.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Investigation without a known mechanism. Requires reasoning over log sequences, race-window timing analysis, and judgment about which of 5 hypothesis branches to pursue. No existing pattern — each possible root cause has a different fix shape.

## PR Conventions

Leaf issue initially. May become `parent-task` if investigation identifies multiple fix vectors.

## Status

**BLOCKED — needs repro data.** Do not dispatch until:

- Timestamps + issue numbers for all cascade events
- `gh issue view` snapshot of parent at cascade time
- `pulse-wrapper.log` excerpt spanning cascade window
- `env | grep ISSUE_CONSOLIDATION` from runner
- `jq '.initialized_repos[] | select(.pulse==true)' ~/.config/aidevops/repos.json` (runner count)
- `~/.aidevops/cache/pulse-instance-lock` contents if present

The `needs-maintainer-review` label prevents pulse dispatch. Once data arrives, maintainer approves the task and the label is cleared.

## How

See issue body at https://github.com/marcusquinn/aidevops/issues/19347 — contains the 5-branch hypothesis tree and investigation methodology.

### Files to Investigate (not modify)

- `.agents/scripts/pulse-triage.sh` — `_issue_needs_consolidation`, `_dispatch_issue_consolidation`, `_consolidation_child_exists`, `_reevaluate_consolidation_labels`
- `.agents/scripts/pulse-wrapper.sh` — pulse instance lock, sourcing order
- `~/.aidevops/cache/pulse-instance-lock` — lock file state

### Investigation Steps

1. Rule out config drift (hypothesis 5) via env dump.
2. Trace function return codes in logs around cascade window.
3. Measure gap between `_consolidation_child_exists` lookup and first child create → race window.
4. If race: atomic create-if-absent via file lock.
5. If label ping-pong: fix re-trigger logic.
6. If comment leak: extend regex filter at `pulse-triage.sh:287-301` (Phase 1 location).

### Verification

- Regression test replaying the observed cascade event sequence must fail against buggy code and pass against the fix.
- No new cascades observed in production for 7 days after fix merges.

## Acceptance criteria

- [ ] Repro data received and logged on #19347
- [ ] Root cause identified with evidence
- [ ] Phase 1 (#19343) merged first (rule out defensive theory)
- [ ] Fix designed; spawns child task(s) or direct PR
- [ ] Regression test added
- [ ] 7-day production stability window after fix

## Out of scope

- Defensive var hardening (#19343)
- Module-level default centralization (#19346)

Ref #19255
