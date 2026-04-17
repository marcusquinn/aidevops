<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2163: parent — large-file simplification gate, phantom continuation root cause + 5-fix plan

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:interactive (Claude Sonnet 4.7)
- **Created by:** Marcus Quinn (ai-interactive)
- **Conversation context:** Surfaced while triaging GH#19415 (t2152) — the user noticed it was held by `needs-simplification` and asked whether the simplification task was actually being created and solved. Investigation revealed that the gate's "Simplification issues: #18706 (recently-closed — continuation)" comment was a phantom: the cited issue was a function-complexity ticket whose merge PR (#18715) added net +29 lines to the file (file went from ~2165 to 2194 lines, still over the 2000-line threshold), and no real file-size simplification work was scheduled.

## What

Drive a systemic fix for the large-file simplification gate's phantom-continuation pattern. The gate has three independent bugs that compound:

1. **Path extractor over-matches** — `_large_file_gate_extract_paths` in `pulse-dispatch-large-file-gate.sh` matches any backticked `.sh`/`.py`/`.js`/`.ts` path on a `-`-list item, regardless of whether the line carries an `EDIT:`/`NEW:`/`File:` intent prefix. Brief authors routinely cite related files for investigation context (e.g. as `grep -rn` search targets), and those citations trip the gate as if they were edit targets.
2. **Continuation dedup has no outcome verification** — `_large_file_gate_create_debt_issue` cites a recently-closed `simplification-debt` issue as "continuation" without checking whether the prior PR actually reduced the file below threshold. This conflates function-complexity simplification with file-size simplification and lets failed prior attempts permanently strand the gate.
3. **`simplification-debt` label is overloaded** — both the daily complexity scan (function >100 lines) and the file-size gate (file >2000 lines) produce `simplification-debt` issues. The dedup matches on basename + label + 30-day window, with no signal to distinguish the two problem classes.

## Why

Concrete failure (GH#19415, t2152): an investigation task targeting `pulse-triage.sh` (1384 lines, under threshold) was held by `needs-simplification` because the brief mentioned `.agents/scripts/issue-sync-helper.sh` (2194 lines) as a `grep` search target on a `-`-list item. The gate's bot comment cited #18706 as in-flight continuation, but #18706 had already closed via PR #18715 with no file-size reduction. Net effect: the parent issue is held indefinitely behind a gate that points to no actual work.

This pattern will recur for every new gated issue while these bugs stand. Fix A+B together unblock GH#19415 immediately; C/D/E close the recurrence loop.

## Tier

**Selected tier:** `tier:thinking` (parent only — children carry their own tier)

**Tier rationale:** This issue is a `parent-task`. It is never dispatched directly. Each child issue carries its own brief and tier. The parent stays open until all five children merge.

## How (5-fix plan)

### Fix A — tighten path extraction in `_large_file_gate_extract_paths`

- **Child issue:** GH#19483 (t2164)
- **EDIT:** `.agents/scripts/pulse-dispatch-large-file-gate.sh:160`
- Change the line filter from `^\s*[-*]\s|^(EDIT|NEW|File):` to `^\s*[-*]\s+(EDIT|NEW|File):|^(EDIT|NEW|File):` so backtick paths are extracted only when the line carries an explicit edit-intent prefix.
- Brief authors who declare intent (`EDIT:`/`NEW:`/`File:`) get matched; brief authors who cite context for investigation do not.

### Fix B — verify file size before declaring continuation

- **Child issue:** GH#19483 (t2164)
- **EDIT:** `.agents/scripts/pulse-dispatch-large-file-gate.sh:286-305`
- Thread `repo_path` into `_large_file_gate_create_debt_issue` and `_large_file_gate_apply`.
- Before returning `(recently-closed — continuation)`, run `wc -l` on the target file. Only short-circuit when the file is now under threshold; otherwise fall through to file a fresh debt issue with a `**Prior attempt:** #NNN closed without reducing file size` reference in the body.
- Preserve pre-t2164 behaviour (trust the closed signal) when `repo_path` is missing or the file isn't on disk in this checkout — measurement-unavailable is safer-as-continuation than safer-as-duplicate.

### Fix C — split the overloaded `simplification-debt` label

- **Child issue:** to be filed when A+B land
- Use `file-size-debt` for the large-file gate and `function-complexity-debt` for the daily scan (or rename `simplification-debt` to one of the two and pick a new name for the other). Update the dedup queries in both producers and any consumers (label-sync, pulse-triage clear paths).
- Migration: a one-shot script to relabel existing open issues based on title pattern (`simplification: reduce function complexity in ...` vs `simplification-debt: ... exceeds N lines`).

### Fix D — outcome check on PR merge

- **Child issue:** to be filed when A+B land
- **NEW:** `.github/workflows/simplification-outcome-check.yml`
- When a PR closes a `file-size-debt` (post-Fix-C) issue, verify the target file is now under threshold. If not, post a comment, reopen the issue, and apply a `simplification-incomplete` label so the gate's dedup can distinguish "did not solve" from "was never tried".

### Fix E — re-evaluate stale "continuation" references in `pulse-triage`

- **Child issue:** to be filed when A+B land
- **EDIT:** `.agents/scripts/pulse-triage.sh:450-491` (`_reevaluate_simplification_labels`)
- When re-evaluating a `needs-simplification`-labeled issue, parse the gate's comment to find the cited continuation issue. If that issue is closed AND the file is still over threshold (per Fix B's wc-l check), clear the stale `needs-simplification` label and let the next dispatch cycle re-fire the gate (which, post-Fix-B, will create a fresh debt issue rather than re-cite the failed one).

## Acceptance criteria

- [ ] Fix A + Fix B child (GH#19483 / t2164) merges and unblocks GH#19415
- [ ] Fix C child filed, merged, and existing open `simplification-debt` issues migrated to the split labels
- [ ] Fix D child filed, merged, and a deliberate "did not solve" PR triggers the reopen path
- [ ] Fix E child filed, merged, and a manual re-eval against an issue with a stale continuation reference clears the label
- [ ] Memory entry stored summarising the gate's three-bug interaction so future sessions don't reinvent the diagnosis

## Out of scope

- Generalising the brief-template's `EDIT:`/`NEW:`/`File:` convention beyond the gate (worker prompt templates, /define interview, etc.) — separate task if needed.
- Changing `LARGE_FILE_LINE_THRESHOLD` from 2000 — this issue is about the gate's correctness given the threshold, not about the threshold itself.

## PR Conventions

`#parent` issue. Every child PR uses `For #19482` (NEVER `Closes`/`Resolves`/`Fixes` until the final phase child). The parent issue stays open until all five fixes merge; the last merging child PR uses `Closes #19482`.

Ref #19415 (the blocked investigation that surfaced this)
