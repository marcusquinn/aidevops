---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1912: Post-merge re-queue for files still above Qlty threshold

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:qlty-maintainability-a-grade
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability badge dropped to C. Investigation found that t1858 (provider-auth.mjs) and t1861 (email_jmap_adapter.py) were marked completed but Qlty still flags them with high complexity (334 and 156 respectively). The simplification loop has no post-merge verification — once an issue closes, nobody checks if the smells actually resolved. Additionally, 4 high-complexity files (index.mjs at 223, extraction_pipeline.py at 211, proxy.js at 171, extract.py at 168) have no simplification tasks at all and should be detected by the scanner.

## What

Extend `_simplification_state_backfill_closed()` in `pulse-wrapper.sh` to verify that Qlty smells are actually resolved after a simplification PR merges. If smells persist, create a follow-up `simplification-debt` issue with incremented pass count and a reference to the original issue. Also extend the `_scan_*` functions (once t1910 lands) to create issues for files that have Qlty smells but no existing open `simplification-debt` issue.

## Why

- t1858 and t1861 completed but smells persist — the loop has no verification step
- 4 high-complexity files have no tasks because the scanner was blind to them (t1910 fixes detection, this task fixes the response)
- Without re-queue, each simplification attempt is fire-and-forget — partial reductions get counted as success
- The convergence mechanism (`SIMPLIFICATION_MAX_PASSES`) counts passes but doesn't check outcomes

## Tier

`tier:standard`

**Tier rationale:** Modifying existing functions in pulse-wrapper.sh, following established patterns. The `_simplification_state_backfill_closed()` function already handles closed issues — this extends it with a verification step.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-wrapper.sh:5207-5280` — extend `_simplification_state_backfill_closed()` to verify smells after recording hash
- `EDIT: .agents/scripts/pulse-wrapper.sh:5480-5600` — extend the scan-to-issue creation loop to check for existing open issues before creating new ones for Qlty-detected violations

### Implementation Steps

1. After recording the hash in `_simplification_state_backfill_closed()` (around line 5267), add a Qlty smell verification step:

```bash
# Post-merge smell verification: check if qlty still flags this file
if command -v qlty >/dev/null 2>&1 || [[ -x "$HOME/.qlty/bin/qlty" ]]; then
    local qlty_cmd="${HOME}/.qlty/bin/qlty"
    local remaining_smells
    remaining_smells=$("$qlty_cmd" smells --all "$full_path" 2>/dev/null | grep -c '^[^ ]' || echo "0")
    if [[ "$remaining_smells" -gt 0 && "$new_passes" -lt "$SIMPLIFICATION_MAX_PASSES" ]]; then
        # Check for existing open issue first
        local existing_open
        existing_open=$(gh issue list --repo "$aidevops_slug" \
            --label "simplification-debt" --state open \
            --search "\"${file_path}\" in:title" --json number --jq 'length' 2>/dev/null) || existing_open="0"
        if [[ "$existing_open" -eq 0 ]]; then
            # Create follow-up issue
            _create_requeue_issue "$aidevops_slug" "$file_path" "$remaining_smells" "$new_passes" "$issue_num"
        fi
    fi
fi
```

2. Add `_create_requeue_issue()` helper that creates a `simplification-debt` issue with:
   - Title: `simplification: re-queue ${file_path} (pass ${new_passes}, ${remaining_smells} smells remaining)`
   - Body referencing the original issue and what the previous pass accomplished
   - Labels: `simplification-debt`, `auto-dispatch`, `tier:standard`
   - Pass count in body for the next worker's context

3. Add the `SIMPLIFICATION_MAX_PASSES` check (default 3) to prevent infinite re-queue loops — after 3 passes, the file is "converged" and escalated to `tier:reasoning` instead of re-queued at standard.

### Verification

```bash
# Function exists and handles the re-queue path
rg '_create_requeue_issue' .agents/scripts/pulse-wrapper.sh

# ShellCheck clean
shellcheck .agents/scripts/pulse-wrapper.sh

# Backfill function still handles the happy path (no regression)
rg '_simplification_state_backfill_closed' .agents/scripts/pulse-wrapper.sh
```

## Acceptance Criteria

- [ ] `_simplification_state_backfill_closed()` checks Qlty smells after recording hash for closed issues
  ```yaml
  verify:
    method: codebase
    pattern: "qlty smells"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] Follow-up issues are created when smells persist after merge, with pass count incremented
- [ ] Dedup check prevents duplicate re-queue issues for the same file
- [ ] `SIMPLIFICATION_MAX_PASSES` (default 3) prevents infinite re-queue — files past max passes escalate to `tier:reasoning`
- [ ] Follow-up issue body references the original closed issue for context continuity
- [ ] ShellCheck clean on pulse-wrapper.sh (at least the modified functions)
  ```yaml
  verify:
    method: bash
    run: "shellcheck -S error .agents/scripts/pulse-wrapper.sh 2>&1 | head -5; echo 'checked'"
  ```

## Context & Decisions

- The re-queue creates a NEW issue, not a reopen — this provides a clean audit trail of each pass
- Pass count is tracked in both `simplification-state.json` and the issue title for visibility
- After max passes (3), escalation to `tier:reasoning` signals that the file needs architectural decomposition, not incremental simplification
- Qlty CLI availability is optional — if not installed (e.g., on Linux CI runners), the verification step is skipped silently and the function behaves as before
- This depends on t1910 for the scanner to detect new offenders, but the backfill verification works independently

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh:5207-5280` — `_simplification_state_backfill_closed()` target
- `.agents/scripts/pulse-wrapper.sh:5480-5600` — scan-to-issue creation loop
- `.agents/scripts/pulse-wrapper.sh:4958-5010` — `_simplification_state_check()` for state lookup pattern
- `.agents/scripts/complexity-scan-helper.sh` — scanner that feeds the pulse (extended by t1910)
- `.agents/configs/simplification-state.json` — state file with hash/passes tracking

## Dependencies

- **Blocked by:** t1910 (scanner must detect Python/JS files for new-offender detection)
- **Blocks:** sustained A-grade recovery (closes the "completed but unresolved" gap)
- **External:** Qlty CLI (`~/.qlty/bin/qlty`) for post-merge verification (optional, degrades gracefully)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Review backfill function, state file format |
| Implementation | 2h | Extend backfill, add _create_requeue_issue, dedup logic |
| Testing | 30m | Verify with known incomplete simplification (t1858 file) |
| **Total** | **~2.5h** | |
