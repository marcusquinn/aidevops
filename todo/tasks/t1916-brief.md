---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1916: Remove approval gate from pulse triage dispatch

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human, interactive session)
- **Conversation context:** User noticed pulse stopped posting triage analysis comments on external `needs-maintainer-review` issues. Investigation revealed t1894's cryptographic approval gate blocks triage dispatch — but triage (read + comment) should run before approval to help the maintainer decide.

## What

Remove the `issue_has_required_approval` check from `dispatch_triage_reviews()` in `pulse-wrapper.sh`. After this change, the pulse will post triage analysis comments on any `needs-maintainer-review` issue without requiring prior cryptographic approval. The approval gate remains on implementation dispatch (`dispatch_with_dedup`) where it belongs.

## Why

The triage comment is the thing that helps the maintainer decide whether to approve an issue. Blocking triage before approval forces manual review of every external issue, defeating the purpose of the triage pipeline. This regression was introduced by t1894 (security hardening) which applied the gate too broadly.

## Tier

`tier:standard`

**Tier rationale:** Single-file edit, clear code block to remove, but requires understanding the security boundary between triage and dispatch to confirm correctness.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-wrapper.sh:10803-10813` — remove the approval gate block from `dispatch_triage_reviews()`

### Implementation Steps

1. Remove the approval gate block (lines 10803-10813):

```bash
# Remove this entire block from dispatch_triage_reviews():
		# ── Cryptographic approval gate (GH#17490) ──
		# Triage reviews are sandboxed but their OUTPUT is posted as a GitHub
		# comment under the maintainer's account. Without this gate, any
		# external non-contributor issue triggers automated actions (worker
		# dispatch, comment posting, resource consumption). The same approval
		# gate enforced by dispatch_with_dedup() must also apply here —
		# no automated processing of unapproved external issues.
		if ! issue_has_required_approval "$issue_num" "$repo_slug" "unknown"; then
			echo "[pulse-wrapper] dispatch_triage_reviews: BLOCKED #${issue_num} in ${repo_slug} — requires cryptographic approval before triage" >>"$LOGFILE"
			continue
		fi
```

2. Add a comment explaining why triage is exempt:

```bash
		# Note: No approval gate here. Triage is read + comment — it helps the
		# maintainer decide whether to approve. The approval gate is enforced
		# on implementation dispatch (dispatch_with_dedup), not triage.
```

3. Verify:

```bash
shellcheck .agents/scripts/pulse-wrapper.sh
rg 'issue_has_required_approval' .agents/scripts/pulse-wrapper.sh
# Should exist in dispatch_with_dedup and issue_has_required_approval definition, NOT in dispatch_triage_reviews
```

### Verification

```bash
# Approval gate removed from triage but preserved in dispatch
rg -n 'issue_has_required_approval' .agents/scripts/pulse-wrapper.sh | grep -v 'dispatch_triage'
# Should return matches (definition + dispatch_with_dedup usage)

rg -A2 'issue_has_required_approval' .agents/scripts/pulse-wrapper.sh | grep -c 'dispatch_triage'
# Should return 0

shellcheck .agents/scripts/pulse-wrapper.sh
```

## Acceptance Criteria

- [ ] `dispatch_triage_reviews()` no longer calls `issue_has_required_approval`
  ```yaml
  verify:
    method: bash
    run: "! rg 'issue_has_required_approval' .agents/scripts/pulse-wrapper.sh | grep -q 'dispatch_triage'"
  ```
- [ ] `dispatch_with_dedup()` still calls `issue_has_required_approval` (security preserved)
  ```yaml
  verify:
    method: codebase
    pattern: "issue_has_required_approval"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] ShellCheck clean
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-wrapper.sh"
  ```
- [ ] Triage comment posted on GH#17695 after next pulse cycle (manual verification)
  ```yaml
  verify:
    method: manual
    prompt: "Check GH#17695 for a triage analysis comment from the pulse"
  ```

## Context & Decisions

- t1894 added the approval gate to prevent automated processing of unapproved external issues — correct for dispatch, overly broad for triage
- Triage is sandboxed (pre-fetched data, no code execution) — the comment IS the desired output
- The comment in the original code (line 10804) acknowledges triage is sandboxed but applies the gate anyway for resource consumption reasons — user has decided the triage value outweighs the token cost
- Approval gate stays on dispatch_with_dedup — no reduction in security for implementation workers

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh:10803-10813` — the block to remove
- `.agents/scripts/pulse-wrapper.sh:4295-4317` — `issue_has_required_approval()` definition (unchanged)
- `.agents/scripts/pulse-wrapper.sh:6786-6793` — approval gate in dispatch path (unchanged)

## Dependencies

- **Blocked by:** none
- **Blocks:** triage comments on GH#17695 and all future `needs-maintainer-review` issues
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Already done in this session |
| Implementation | 10m | Remove block, add comment |
| Testing | 10m | shellcheck + manual triage test |
| **Total** | **25m** | |
