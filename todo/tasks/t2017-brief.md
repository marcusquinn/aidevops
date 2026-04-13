---
task_id: t2017
title: Teach /review-issue-pr to do temporal-duplicate, framing, and second-order-effects checks
status: completed
---

## What

Enhance `.agents/workflows/review-issue-pr.md` with six targeted insertions to bake lessons from the t2014/t2015 session into the interactive review workflow. The agent now runs temporal-duplicate, framing, and second-order-effects checks before accepting proposed fixes.

## Why

The t2014/t2015 session surfaced three specific review mistakes that a well-designed review agent should catch upfront:

1. **Temporal-duplicate blindness** — missed a recent commit that fixed the same problem
2. **Framing acceptance** — reasoned from the user's framing without verifying it matched codebase reality
3. **Symptom-vs-root-cause confusion** — proposed reducing retry limits when the real issue was a broken retry target

These aren't abstract improvements — they're the actual mistakes from one recent session, each catchable by a specific check.

## How

Six targeted insertions into `.agents/workflows/review-issue-pr.md`:

1. **New Section 0 "Pre-Review Discovery (MANDATORY)"** — three sub-checks:
   - 0.1 Duplicate and temporal-duplicate check
   - 0.2 Affected-files discovery
   - 0.3 Framing critique

2. **Section 1 strengthening** — replace `Not duplicate` with two rows: `Not a pre-existing duplicate` AND `Not superseded by recent work`

3. **New Section 6 "Second-Order Effects and Safety Gates"** — four sub-checks:
   - 6.1 Architectural intent
   - 6.2 Safety gate interaction
   - 6.3 Symptom vs root cause
   - 6.4 Ripple effects

4. **Output format updates** — two new sub-sections:
   - `### Pre-Review Context` (discovery findings)
   - `### Second-Order Effects` (architecture/gates/root-cause/ripple)

5. **Three new scenario templates** at the bottom of "Common Scenarios":
   - Issue Already Superseded by Recent Work
   - Fix Addresses Symptom, Root Cause Lives Elsewhere
   - Fix Defeats a Recent Architectural Decision

6. **Gap note for sandboxed triage path** — added to the Headless / Pulse-Driven Mode section, flagging that the sandboxed `triage-review.md` agent has no Bash/network and requires a follow-up to extend the prefetch in `pulse-ancillary-dispatch.sh`.

## Acceptance Criteria

- [x] Section 0 "Pre-Review Discovery (MANDATORY)" present with 0.1, 0.2, 0.3
- [x] Section 1 has two duplicate rows (pre-existing + temporal)
- [x] Section 6 "Second-Order Effects and Safety Gates" present with 6.1, 6.2, 6.3, 6.4
- [x] Review Output Format includes "Pre-Review Context" and "Second-Order Effects" sections
- [x] Three new scenario templates added
- [x] Gap note (t2017) present in Headless / Pulse-Driven Mode section
- [x] Markdown linting passes (0 errors)
- [x] All verification commands from issue pass

## Verification

```bash
# Structural sanity — all sections present
rg -n '^## [0-9]\.|^### [0-9]\.|^#### [0-9]\.[0-9]' .agents/workflows/review-issue-pr.md

# Expected:
# 0. Pre-Review Discovery (MANDATORY) + 0.1, 0.2, 0.3
# 1. Problem Validation (unchanged header)
# 2-5. unchanged
# 6. Second-Order Effects and Safety Gates + 6.1, 6.2, 6.3, 6.4

# New scenarios present
rg -c '^### Issue Already Superseded|^### Fix Addresses Symptom|^### Fix Defeats a Recent' .agents/workflows/review-issue-pr.md
# → 3

# Gap note present
rg -n 'Gap \(t2017\)' .agents/workflows/review-issue-pr.md
# → one match in the Headless / Pulse-Driven Mode section

# Markdown lint
npx markdownlint-cli2 .agents/workflows/review-issue-pr.md
# → 0 error(s)
```

All verification steps pass.

## Files Changed

- `.agents/workflows/review-issue-pr.md` — six insertion edits (+150 lines net)

## Related

- **Session context**: #18471 (t2014 — cut `TRIAGE_MAX_RETRIES` 3→1, merged) and #18473 (triage JSONL parsing root cause, open)
- **Architectural reference**: t1998 (simplification gate `force_recheck` parameter — the fix the first proposal would have defeated had it landed)
- **Follow-up**: prefetch enhancement in `pulse-ancillary-dispatch.sh` so sandboxed triage gets the same discipline (to be filed separately)
