<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2164: fix(large-file-gate) — tighten path extraction + verify file size before declaring continuation

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:interactive (Claude Sonnet 4.7)
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** t2163 / GH#19482 (5-fix plan)
- **Conversation context:** Immediate unblock child for GH#19415 (t2152). The parent task (t2163) documents all three bugs; this child delivers Fix A and Fix B together because both are surgical edits in the same file and both are needed to clear the phantom-continuation state.

## What

Two fixes to `.agents/scripts/pulse-dispatch-large-file-gate.sh`:

**Fix A — narrow the path extractor.** In `_large_file_gate_extract_paths` (line 138-178), tighten the line filter so backtick paths are extracted only when the line carries an explicit `EDIT:`/`NEW:`/`File:` intent prefix. The previous regex (`^\s*[-*]\s|^(EDIT|NEW|File):`) matched any backticked `.sh`/`.py`/`.js`/`.ts` path on a `-`-list item, regardless of whether it was an edit target or a context reference.

**Fix B — verify the prior simplification actually worked.** In `_large_file_gate_create_debt_issue` (line 286-395), before returning `(recently-closed — continuation)` for a closed `simplification-debt` issue within the 30-day reopen window, run `wc -l` on the target file. Only short-circuit when the file is now under threshold. If still over, log and fall through to file a fresh debt issue with a `**Prior attempt:** #NNN closed without reducing file size` reference in the body. Thread `repo_path` through `_large_file_gate_apply` and `_issue_targets_large_files` to supply the path.

## Why

Concrete failure (GH#19415, t2152):

- Investigation task targeting `pulse-triage.sh:255-330` (1384 lines, under threshold) got held by `needs-simplification` because the brief listed `.agents/scripts/issue-sync-helper.sh` (2194 lines) as a `grep` search target on a list item.
- Gate's bot comment cited `#18706 (recently-closed — continuation)`, but #18706 was a function-complexity ticket whose merge PR #18715 added net **+29 lines** to the file (from ~2165 to 2194). No file-size simplification was in flight.
- Without both fixes, a similar pattern will recur for every gated issue whose brief mentions another over-threshold file for context, and every file whose previous simplification attempt didn't reduce line count.

Fix A alone unblocks the specific issue. Fix B alone closes the recurring cause. Shipping them together prevents a second pass.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Two surgical edits in one file, a shared-threshold regex change, and argument threading. Narrative brief with exact file+line references — Sonnet-tier territory. Not `tier:simple` because the diagnosis requires understanding the three-bug interaction (though the edits themselves are local).

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-dispatch-large-file-gate.sh`
  - Fix A: rewrite `_large_file_gate_extract_paths` regex
  - Fix B: add wc-l verification in `_large_file_gate_create_debt_issue`; thread `repo_path` through `_large_file_gate_apply` and the orchestrator call
- **NEW:** `.agents/scripts/tests/test-large-file-gate-extract-edit-only.sh` — Fix A regression (8 assertions)
- **NEW:** `.agents/scripts/tests/test-large-file-gate-continuation-verify.sh` — Fix B regression (7 assertions)

### Reference patterns

- Test style: `tests/test-simplification-backfill-extract-path.sh` (form A/B/C assertion pattern)
- Stub pattern: `tests/test-auto-dispatch-no-assign.sh` (shell-function `gh` stub after source)
- Module style: existing helpers in `pulse-dispatch-large-file-gate.sh` (`_LFG_` prefix, return-code conventions, `>>"$LOGFILE"` logging)

### Verification

```bash
bash -n .agents/scripts/pulse-dispatch-large-file-gate.sh
shellcheck .agents/scripts/pulse-dispatch-large-file-gate.sh
.agents/scripts/tests/test-large-file-gate-extract-edit-only.sh        # 8/8
.agents/scripts/tests/test-large-file-gate-continuation-verify.sh      # 7/7
# regression: existing related tests
.agents/scripts/tests/test-simplification-backfill-extract-path.sh      # 8/8
.agents/scripts/tests/test-simplification-spurious-sweep.sh             # 10/10
```

After merge, manual re-eval against GH#19415 must clear `needs-simplification` (the `issue-sync-helper.sh` line no longer extracts).

## Acceptance criteria

- [x] `_large_file_gate_extract_paths` returns empty for the GH#19415 brief excerpt; returns only declared paths for the same brief with `EDIT:` prefixes
- [x] `_large_file_gate_create_debt_issue` does NOT return continuation when the cited file is still over threshold; returns `(new)` with prior-attempt reference in the body instead
- [x] Backward-compat preserved: no `repo_path` or file not on disk → returns continuation (pre-t2164 behaviour)
- [x] Two regression tests (15 assertions total) pass; existing tests remain green
- [ ] Manual re-eval against GH#19415 after merge clears the label

## Out of scope

- Fixes C, D, E from the parent plan (separate child issues)
- Renaming `simplification-debt` or splitting it into `file-size-debt` / `function-complexity-debt` (Fix C)
- Changes to `LARGE_FILE_LINE_THRESHOLD` itself

## PR Conventions

Leaf child of parent-task #19482. Use `Resolves #19483` (closes this child on merge) AND `For #19482` (references parent without closing). Parent stays open until Fixes C/D/E also merge.

Ref #19415
