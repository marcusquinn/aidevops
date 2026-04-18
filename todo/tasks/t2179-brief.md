---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2179: feat(pulse-merge): coderabbit-nits-ok label to dismiss CodeRabbit nitpick-only CHANGES_REQUESTED

## Origin

- **Created:** 2026-04-18
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** While clearing 4 stuck PRs in `marcusquinn/aidevops`, PR #19630 (t2174 opencode-db-maintenance) sat BLOCKED for ~1 hour with all CI green. The blocker was a CodeRabbit `CHANGES_REQUESTED` review whose actionable items were pure cosmetics (function ordering, dead var, fence language tag). User asked: "should the pulse have a way to honour these as 'I've read them, ship it' without me dismissing each time?"

## What

A new PR label `coderabbit-nits-ok` that, when applied to a PR, causes the pulse merge gate to:

1. Detect that the PR has `reviewDecision: CHANGES_REQUESTED`
2. Verify EVERY CHANGES_REQUESTED review on the PR is authored by `coderabbitai[bot]` (not a human)
3. Auto-dismiss those CodeRabbit reviews with a templated audit message
4. Continue the merge gate flow (don't return 1)

If a human reviewer also requested changes, the label is ignored and the normal CHANGES_REQUESTED skip applies — humans are never auto-dismissed.

When done, an interactive maintainer can tag a green PR with `coderabbit-nits-ok`, walk away, and the pulse merge pass picks it up on the next cycle without further action.

## Why

CodeRabbit posts CHANGES_REQUESTED for any "actionable" finding, regardless of severity. Many actionable items are pure cosmetics: function-ordering nits, dead variable cleanup, MD040 language-tag suggestions. The pulse merge gate (`pulse-merge.sh:760-775`) correctly treats CHANGES_REQUESTED as blocking — branch protection honours it from any reviewer once on the PR. Result: green-CI maintainer PRs sit blocked, requiring manual `gh api PUT /reviews/<id>/dismissals` invocation per PR.

Concrete evidence (2026-04-18): PR #19630 had 30+ CI checks green, 2 actionable + 4 nitpick CodeRabbit findings (function ordering, dead `HOME_BACKUP` var, missing ` ```text ` fence tag, `bc` fallback polish, VACUUM stderr capture, JSON-parse fallback). Zero of the six were merge-blocking. Manual dismiss took 30s but had to be done by a human in the chat session.

This pattern recurs daily on framework PRs. The override label is the human's "I read these and they're fine" signal — same shape as `ratchet-bump` (qlty-regression), `new-file-smell-ok` (qlty-new-file-gate), and `complexity-bump-ok` (per-metric regression). Each exists because automated quality gates have a long-tail false-positive rate that maintainers need a fast escape hatch from.

Doing nothing means we keep paying ~30s per affected PR forever, and worse, we keep training the next interactive session to "always check for stuck CodeRabbit blockers" — invisible cognitive overhead that compounds.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (pulse-merge.sh + new test file = 2)
- [ ] **Every target file under 500 lines?** `pulse-merge.sh` is ~2200 lines
- [ ] **Exact `oldString`/`newString` for every edit?** (helper function needs design)
- [x] **No judgment or design decisions?** (pattern is established by ratchet-bump)
- [x] **No error handling or fallback logic to design?** (best-effort dismiss; on failure, fall through to skip)
- [x] **No cross-package or cross-module changes?** (pulse-merge.sh only)
- [x] **Estimate 1h or less?** (~1.5h with tests)
- [x] **4 or fewer acceptance criteria?** (4)

**Selected tier:** `tier:standard`

**Tier rationale:** Two checklist failures: pulse-merge.sh > 500 lines so the worker has to navigate the file (judgment work), and the helper needs a small amount of design (which API to call, how to format the dismiss message, how to enumerate CR reviews). Pattern is established (ratchet-bump) but not a verbatim copy. Sonnet handles this comfortably.

## PR Conventions

Leaf task. PR body: `Resolves #19639`.

## How (Approach)

### Worker Quick-Start

- Pulse merge gate logic: `.agents/scripts/pulse-merge.sh:740-855` (function `_check_pr_merge_gates`)
- CHANGES_REQUESTED branch to extend: lines 760-775
- Override-label pattern reference: `.github/workflows/qlty-regression.yml` `ratchet-bump` handling
- Manual dismiss API (already proven working in this session): `gh api -X PUT "repos/<slug>/pulls/<num>/reviews/<id>/dismissals" -f message="..."`
- List CHANGES_REQUESTED reviews: `gh api "repos/<slug>/pulls/<num>/reviews" --jq '.[] | select(.state=="CHANGES_REQUESTED") | {id, login: .user.login}'`

### Files to Modify

- **EDIT:** `.agents/scripts/pulse-merge.sh:760-775` — extend the `pr_review == CHANGES_REQUESTED` branch with the override-label check
- **EDIT:** `.agents/scripts/pulse-merge.sh` (find a sensible spot near other helpers, ~line 700) — add new `_pulse_merge_dismiss_coderabbit_nits` helper
- **NEW:** `.agents/scripts/tests/test-pulse-merge-coderabbit-nits-ok.sh` — model structure on existing `test-pulse-merge-*.sh` files
- **EDIT:** `.agents/AGENTS.md` "Review Bot Gate (t1382)" section — document the override label and when to use it (one-line addition referencing the new helper)

### Implementation Steps

1. **Add helper `_pulse_merge_dismiss_coderabbit_nits` in `pulse-merge.sh`:**
    - Args: `pr_number`, `repo_slug`
    - Returns: 0 if all CR reviews dismissed (or none existed), 1 if a non-CR human review blocks dismissal
    - Implementation:
      - `gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" --jq '[.[] | select(.state=="CHANGES_REQUESTED")] | map({id, login: .user.login})'`
      - Iterate; if any login is NOT `coderabbitai[bot]`, return 1 immediately
      - Otherwise dismiss each via `gh api -X PUT ".../pulls/${pr_number}/reviews/${id}/dismissals" -f message="Auto-dismissed: coderabbit-nits-ok label applied by maintainer (PR #${pr_number})"`
      - Log each dismissal to `$LOGFILE`
2. **Extend `_check_pr_merge_gates` CHANGES_REQUESTED branch (line 760-775):**
    - Before the existing `_dispatch_pr_fix_worker` routing, fetch PR labels (the existing block at 762-764 already does this; reuse `_cr_pr_labels`)
    - If labels contain `coderabbit-nits-ok` AND `_pulse_merge_dismiss_coderabbit_nits` returns 0, log "auto-dismissed CR-only CHANGES_REQUESTED" and proceed (do NOT return 1, fall through to next gate)
    - If labels contain `coderabbit-nits-ok` AND helper returns 1 (human reviewer present), log "skipped: coderabbit-nits-ok label present but human reviewer also blocking" and return 1 (preserve existing behaviour)
    - If label absent, preserve existing behaviour exactly
3. **Test (`test-pulse-merge-coderabbit-nits-ok.sh`):**
    - Mock `gh` via `PATH` shim returning fixture JSON
    - Case A: no label → existing skip behaviour (return 1, no API calls)
    - Case B: label + only CR reviews → dismiss called, function returns 0
    - Case C: label + mixed (CR + human) → no dismiss, function returns 1
    - Case D: label + zero CHANGES_REQUESTED reviews → return 0 (degenerate, but safe)
4. **Doc update in `.agents/AGENTS.md`:**
    - Find the "Review Bot Gate (t1382)" subsection
    - Add: "**Override:** apply `coderabbit-nits-ok` label to a PR to auto-dismiss CodeRabbit-only CHANGES_REQUESTED reviews on the next merge pass. Label is ignored if a human reviewer also requested changes."

### Verification

- `bash .agents/scripts/tests/test-pulse-merge-coderabbit-nits-ok.sh` — must pass all 4 cases
- `shellcheck .agents/scripts/pulse-merge.sh` — zero new violations
- Manual smoke (post-merge): apply label to a real test PR, watch pulse log for `[pulse-wrapper] Merge pass: PR #N auto-dismissed coderabbit-only CR review and proceeding`

## Acceptance Criteria

- [ ] `coderabbit-nits-ok` label triggers dismiss-and-continue ONLY when every CHANGES_REQUESTED review is from `coderabbitai[bot]`
- [ ] Mixed reviewers (CR + human) → label is ignored, normal skip applies
- [ ] Dismissal carries audit message: `"Auto-dismissed: coderabbit-nits-ok label applied by maintainer (PR #N)"`
- [ ] Pulse log records each dismissal with PR + review ID
- [ ] Test file passes all 4 cases
- [ ] AGENTS.md "Review Bot Gate" subsection documents the override

## Context

- Adjacent override-label patterns: `ratchet-bump` (qlty-regression-helper.sh), `new-file-smell-ok` (qlty-new-file-gate-helper.sh), `complexity-bump-ok` (complexity-regression-helper.sh)
- Related but distinct: `ai-approved` label (collaborator gate, not cryptographic), `<!-- aidevops-signed-approval -->` marker (crypto-signed approval for external contributors). This is neither — it's a "I read CodeRabbit's nits and they're fine" override.
- Concrete evidence PR: #19630 dismissed manually 2026-04-18 at ~04:50 — see API call audit
