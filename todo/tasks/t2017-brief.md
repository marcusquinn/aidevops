<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2017: teach /review-issue-pr to do temporal-duplicate, framing, and second-order-effects checks

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Created by:** ai-interactive (conversation about lessons from the t2014 / #18473 session)
- **Parent task:** none
- **Conversation context:** During the session that produced #18471 (t2014 MAX_RETRIES cut) and #18473 (triage JSONL parsing root cause), the user observed that the agent behind `/review-issue-pr` should have caught several mistakes upfront: proposing a content-hash cache without checking that a related fix (t1998) had just landed; accepting the "lock/unlock for gated issues" framing at face value when no such lock/unlock actually happened on gated issues; and endorsing a retry-count reduction (MAX=1) that made a broken thing cheaper rather than identifying the broken JSON-output parsing as the real bug. This task bakes those lessons into the interactive review workflow.

## What

Add three discovery/analysis sections and two new output sections to `.agents/workflows/review-issue-pr.md`:

1. **Section 0 "Pre-Review Discovery" (new, mandatory)** — three sub-checks run before any other review step:
   - **0.1 Duplicate and temporal-duplicate check** — search existing issues AND `git log --since="<issue date>"` + `gh pr list --state merged --search` for work that superseded the issue after it was posted.
   - **0.2 Affected-files discovery** — read the current contents of the files the issue references, not the state described in the issue body (line numbers drift).
   - **0.3 Framing critique** — verify the issue's cited symptoms match codebase reality; document mismatches before reviewing the proposed fix.

2. **Strengthen Section 1 (Problem Validation)** — replace the single "Not duplicate" row with two rows: "Not a pre-existing duplicate" AND "Not superseded by recent work". The second row is the new discipline.

3. **Section 6 "Second-Order Effects and Safety Gates" (new)** — four sub-checks added after Section 5 (Architecture Alignment):
   - **6.1 Architectural intent** — does the proposal contradict a decision landed in the last 30 days?
   - **6.2 Safety gate interaction** — map the change against seven gates (maintainer approval, sandbox, dedup, prompt injection, privacy guard, review bot, origin labels).
   - **6.3 Symptom vs root cause** — five anti-patterns that signal the proposal is papering over a deeper bug (retry-count reduction, cache defeating re-check, defensive workaround, raised timeout, etc.).
   - **6.4 Ripple effects** — enumerate downstream code paths affected; an empty list is a red flag.

4. **Output format** — add two new output sections before "Scope & Recommendation":
   - `### Pre-Review Context` — records discovery findings (duplicates, temporal supersession, framing, drift)
   - `### Second-Order Effects` — records architectural/gate/root-cause/ripple analysis

5. **Three new "Common Scenarios"** at the bottom, with verbatim comment templates:
   - Issue already superseded by recent work
   - Fix addresses symptom, root cause lives elsewhere
   - Fix defeats a recent architectural decision

6. **Note to "Headless / Pulse-Driven Mode" section** — flag that the sandboxed `triage-review.md` agent cannot run these checks (no Bash/network), so the prefetch in `pulse-ancillary-dispatch.sh` must be extended in a follow-up task to supply recent merged PRs, recent commits, and current file contents.

## Why

Concrete session evidence — every one of these lessons would have prevented a specific mistake from the session that spawned this task:

| Lesson | Would have caught |
|--------|-------------------|
| **Temporal duplicate check (0.1)** | My first proposal was a content-hash cache for the simplification gate. I hadn't checked `git log --since` — t1998 had landed hours before and was the correct fix for the same problem. A one-minute discovery step would have redirected the whole conversation. |
| **Framing critique (0.3)** | The user said "lock/unlock for gated issues". I accepted the framing and reasoned from it. A framing check would have caught that no lock/unlock was actually happening on gated issues — the real issue was in a completely different code path (triage retries). |
| **Symptom vs root cause (6.3)** | My second proposal was `TRIAGE_MAX_RETRIES=1`. That reduces the cost of failing triage by 67%, but the triage was 100% broken (JSONL parsing bug). A root-cause check would have asked "why are the retries failing identically every time?" and led straight to the JSON parser bug as the real issue, not a retry-count tuning exercise. |
| **Architectural intent (6.1)** | My original cache proposal would have defeated t1998's invariant (which specifically re-checks files every cycle so cleared ones can unblock). A cache that skips the re-check would have regressed t1998's fix. Reading the last 30 days of commits on the affected files would have surfaced this. |
| **Safety gate interaction (6.2)** | Not triggered in this specific session, but the sandbox boundary and prompt injection gates are exactly the kind of thing that "it looks simpler without this check" arguments silently erode. Explicit enumeration makes the interaction visible. |

Beyond this specific session, these checks encode the general pattern that the hardest review mistakes aren't about the proposed fix being wrong — they're about the proposed fix being irrelevant, duplicated, or defeating something nearby that the reviewer didn't know about.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Yes — 1 file (`review-issue-pr.md`) plus 1 new brief file (this one)
- [x] **Complete code blocks for every edit?** Yes — the edits are verbatim markdown blocks, fully specified below
- [x] **No judgment or design decisions?** Yes — the content is specified verbatim; no design work left
- [x] **No error handling or fallback logic to design?** Yes — docs change, no runtime logic
- [x] **Estimate 1h or less?** Yes — ~15 minutes including commit/PR ceremony
- [x] **4 or fewer acceptance criteria?** Yes — 4 (see below)

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file docs change with verbatim insertions. No logic, no tests, no runtime behaviour touched. The companion follow-up (prefetch enhancement for sandboxed triage) is explicitly out of scope here — this task ONLY updates the interactive workflow file.

## How (Approach)

### Files to modify

- `EDIT: .agents/workflows/review-issue-pr.md` — insert 6 blocks as described below.

### Implementation

The implementation is already complete in this worktree — the brief documents what landed so a reader can reconstruct the reasoning.

**Edit 1**: Insert new Section 0 before `## Issue Review Checklist`. Section 0 contains:
- 0.1 Duplicate and temporal-duplicate check (3-row table)
- 0.2 Affected-files discovery (bash commands for files/recent-activity/current-contents)
- 0.3 Framing critique (4-bullet list of framing errors to catch)

**Edit 2**: In Section 1 (Problem Validation), replace the `Not duplicate` row with two rows: `Not a pre-existing duplicate` AND `Not superseded by recent work`.

**Edit 3**: Insert new Section 6 after Section 5 (Architecture Alignment), before `## Review Output Format`. Section 6 contains:
- 6.1 Architectural intent (3-row table)
- 6.2 Safety gate interaction (7-row table covering all seven aidevops gates)
- 6.3 Symptom vs root cause (5-row table of anti-patterns)
- 6.4 Ripple effects (6-bullet list + "red flag if empty" note)

**Edit 4**: In the output format block, add `### Pre-Review Context` before `### Issue Validation` (4-row table), strengthen the Issue Validation table with the two new duplicate rows, and add `### Second-Order Effects` before `### Scope & Recommendation` (5-row table).

**Edit 5**: Add three new sub-sections at the bottom of `## Common Scenarios`:
- "Issue Already Superseded by Recent Work"
- "Fix Addresses Symptom, Root Cause Lives Elsewhere"
- "Fix Defeats a Recent Architectural Decision"

**Edit 6**: In `## Headless / Pulse-Driven Mode`, add a `> **Gap (t2017):**` note flagging that the sandboxed `triage-review.md` agent can't run these checks and that the prefetch needs extending in a follow-up task.

### Verification

```bash
# 1. Structural sanity — all sections present and numbered
rg -n '^## [0-9]\.|^### [0-9]\.[0-9]' .agents/workflows/review-issue-pr.md
# Expected: Section 0 with 0.1/0.2/0.3; Section 1 unchanged; Section 6 with 6.1/6.2/6.3/6.4

# 2. All new scenarios present
rg -c '^### Issue Already Superseded|^### Fix Addresses Symptom|^### Fix Defeats a Recent' .agents/workflows/review-issue-pr.md
# Expected: 3

# 3. Output format has the new sub-sections
rg -n '^### Pre-Review Context|^### Second-Order Effects' .agents/workflows/review-issue-pr.md
# Expected: both matched

# 4. Gap note added for sandboxed path
rg -n 'Gap \(t2017\)' .agents/workflows/review-issue-pr.md
# Expected: one match in the Headless / Pulse-Driven Mode section

# 5. Markdown lint (if markdownlint-cli2 installed)
markdownlint-cli2 .agents/workflows/review-issue-pr.md || true
```

## Acceptance Criteria

- [ ] Section 0 "Pre-Review Discovery (MANDATORY)" present with three sub-sections (0.1 duplicate/temporal, 0.2 affected-files, 0.3 framing critique)
  ```yaml
  verify:
    method: codebase
    pattern: "## 0\\. Pre-Review Discovery"
    path: ".agents/workflows/review-issue-pr.md"
  ```
- [ ] Section 6 "Second-Order Effects and Safety Gates" present with four sub-sections (6.1 architectural intent, 6.2 safety gates, 6.3 symptom vs root cause, 6.4 ripple effects)
  ```yaml
  verify:
    method: codebase
    pattern: "### 6\\. Second-Order Effects and Safety Gates"
    path: ".agents/workflows/review-issue-pr.md"
  ```
- [ ] Output format includes `### Pre-Review Context` and `### Second-Order Effects` sub-sections
  ```yaml
  verify:
    method: codebase
    pattern: "### Pre-Review Context"
    path: ".agents/workflows/review-issue-pr.md"
  ```
- [ ] Three new scenarios added: superseded, symptom-vs-root-cause, defeats-architectural-decision
  ```yaml
  verify:
    method: codebase
    pattern: "### Issue Already Superseded by Recent Work"
    path: ".agents/workflows/review-issue-pr.md"
  ```

## Context & Decisions

- **Scope boundary — interactive only**: This task updates only the interactive `/review-issue-pr` workflow. The sandboxed `triage-review.md` agent used by the pulse has no Bash or network tools, so it cannot execute the discovery commands. Bringing the same discipline to pulse triage requires a follow-up task that extends the prefetch in `pulse-ancillary-dispatch.sh` to supply: (1) recent merged PRs matching the issue keywords, (2) recent commits on the affected files since the issue was posted, (3) current file contents at the cited line numbers. A `> **Gap (t2017):**` note in the Headless section flags this explicitly.
- **Why "MANDATORY" on Section 0**: The point of the whole task is to prevent the reviewer from skipping discovery in favour of jumping to the proposed fix. Marking it mandatory in the section heading is a cheap discipline reinforcement.
- **Why enumerate seven safety gates explicitly**: Earlier attempts at shorter checklists ("does this touch any gate?") led to "no" answers because reviewers didn't remember which gates existed. Listing them explicitly is longer but actually usable.
- **Why include "it is often correct to ship both"** in 6.3: Without this, the symptom-vs-root-cause check becomes a purity test that rejects legitimate cost-reduction PRs. The discipline is to make the root cause VISIBLE (via a separate issue) even when endorsing the symptom fix.

## Relevant Files

- `.agents/workflows/review-issue-pr.md` — target file (pre-change: 262 lines, post-change: ~412 lines)
- `.agents/workflows/triage-review.md` — sandboxed variant used by pulse, flagged as follow-up scope
- `.agents/scripts/pulse-ancillary-dispatch.sh` — follow-up scope: prefetch expansion to supply discovery data to sandboxed agent

## Dependencies

- **Blocked by:** none
- **Blocks:** follow-up task for sandboxed-triage prefetch enhancement (to be filed separately)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Edits | 10m | Six targeted Edit calls to one file |
| Brief + verification | 3m | Writing this brief and running sanity checks |
| Commit + PR | 2m | Conventional commit, PR with Resolves link |
| **Total** | **~15m** | |
