<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2139: review-bot-gate: positive completion signal in bot_has_real_review

## Origin

- **Created:** 2026-04-16
- **Session:** opencode (interactive, claude-opus-4-6)
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** External contributor `robstiles` filed GH#19251 with detailed evidence that `bot_has_real_review()` false-positives on CodeRabbit's two-phase placeholder comments, causing PRs to merge before the review completes. After validation, user approved the hybrid (negative-pattern + positive-signal) fix and asked to full-loop through merge/release/deploy.

## What

Replace the negative-only filter in `bot_has_real_review()` with a hybrid classifier that requires:

1. At least one bot comment that does NOT match a known non-review pattern (existing logic, expanded), AND
2. That comment shows positive evidence of completion — either GitHub `reviewDecision` is set, or `updated_at > created_at + min_edit_lag_seconds` (default 30s)

User-visible effect: PRs no longer merge during the ~14-90s window between CodeRabbit's Phase 1 placeholder and Phase 2 completed review. The `do_list` output disambiguates "no review yet" (waiting for Phase 2) from "rate-limited (capacity-exhausted)". Per-tool override available via `review_gate.tools.<bot>.min_edit_lag_seconds` in `repos.json`, slotted into the existing t2123 schema.

## Why

GH#19251 evidence: 7 of 7 sampled PRs on a managed private repo merged at ~76s — exactly one `REVIEW_BOT_POLL_INTERVAL` after CodeRabbit's Phase 1 placeholder. CodeRabbit then edited each comment with "Review failed — Pull request was closed or merged during review." On this repo, PRs #19239 and #19240 merged in 21-23s with "Review skipped" comments that also bypassed the gate. Net result: zero CodeRabbit feedback on these PRs; t2093's `CHANGES_REQUESTED` routing is unreachable; quota burned generating reviews that produce no findings.

Root cause: `bot_has_real_review()` (line 224-260) classifies any comment that doesn't match `RATE_LIMIT_PATTERNS` as a real review. It has no concept of completion — only the absence of known-bad patterns. Two-phase posting and non-rate-limit notices ("Review failed", "Review skipped") slip through.

The t2123 work (PR #19186) only addressed the rate-limited branch (lines 398-417) of `do_check`. The false-positive `found_bots` branch (lines 388-391) was untouched and hit unconditional PASS.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — No (helper + AGENTS.md + tests = 3+)
- [ ] **Every target file under 500 lines?** — `review-bot-gate-helper.sh` is 725 lines
- [ ] **Exact `oldString`/`newString` for every edit?** — No (judgement on classifier integration)
- [ ] **No judgment or design decisions?** — No (settled-check threshold default, integration with rate-limit path)
- [x] **No error handling or fallback logic to design?** — Mostly (graceful fallback if `updated_at` unavailable)
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?** — Borderline 1-2h
- [x] **4 or fewer acceptance criteria?**

3+ files, target file >500 lines, judgment work on threshold defaults and fallback semantics → `tier:standard`.

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file change with judgement on integration semantics (how the settled check interacts with the existing rate-limit branch and `any_bot_has_success_status` fallback). Sonnet handles this; Haiku would mis-design the integration without a verbatim diff.

## PR Conventions

Leaf issue (`bug`, not `parent-task`) → PR body uses `Resolves #19251`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/review-bot-gate-helper.sh:60-70` — Rename `RATE_LIMIT_PATTERNS` to `NON_REVIEW_PATTERNS`, expand patterns to include "Review failed", "Review skipped", "closed or merged during review", "Auto reviews are limited"
- `EDIT: .agents/scripts/review-bot-gate-helper.sh:211-260` — Rename `is_rate_limit_comment` → `is_non_review_comment`. Add `_bot_review_is_settled()` helper. Update `bot_has_real_review()` to require BOTH negative-filter pass AND settled check
- `EDIT: .agents/scripts/review-bot-gate-helper.sh:80-90` — Add `REVIEW_BOT_MIN_EDIT_LAG_SECONDS` env var (default 30) and `_get_min_edit_lag()` resolver mirroring `_get_rate_limit_behavior()`
- `EDIT: .agents/scripts/review-bot-gate-helper.sh:456-491` — `do_list` output: add a "no review yet" classification distinct from "rate-limited"
- `NEW: .agents/scripts/tests/test-review-bot-gate-completion-signal.sh` — Test harness with fixtures for placeholder-only, "Review failed", "Review skipped", edited-old-enough, edited-too-recent, real review
- `EDIT: .agents/AGENTS.md` `review_gate` section — Document new `min_edit_lag_seconds` per-tool field

### Implementation Steps

1. **Rename and expand patterns** (preserve backwards-compat alias):

   ```bash
   # Patterns indicating a comment is NOT a real review (rate limits, failures, skips).
   NON_REVIEW_PATTERNS=(
     "rate limit exceeded"
     "rate limited by coderabbit"
     "daily quota limit"
     "reached your daily quota"
     "Please wait up to 24 hours"
     "has exceeded the limit for the number of"
     "Review failed"
     "Review skipped"
     "closed or merged during review"
     "Auto reviews are limited"
   )
   # Backwards-compat alias for any callers/tests referencing the old name.
   RATE_LIMIT_PATTERNS=("${NON_REVIEW_PATTERNS[@]}")
   ```

2. **Add settled-check helper**:

   ```bash
   # t2139: How long a bot comment must have been "stable" (created_at == updated_at,
   # or updated_at > created_at + min_edit_lag_seconds) before it counts as a
   # completed review. Defeats two-phase placeholder pattern.
   REVIEW_BOT_MIN_EDIT_LAG_SECONDS="${REVIEW_BOT_MIN_EDIT_LAG_SECONDS:-30}"

   _get_min_edit_lag() {
     # Resolution: per-tool > per-repo > env var > 30
     local repo_slug="$1"
     local bot_login="$2"
     local repos_json="${HOME}/.config/aidevops/repos.json"
     if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
       local lag
       lag=$(jq -r --arg slug "$repo_slug" --arg bot "$bot_login" \
         'first(.initialized_repos[] | select(.slug == $slug)) | (.review_gate.tools[$bot].min_edit_lag_seconds // .review_gate.min_edit_lag_seconds // empty)' \
         "$repos_json" 2>/dev/null) || lag=""
       if [[ -n "$lag" && "$lag" =~ ^[0-9]+$ ]]; then
         printf '%s' "$lag"
         return 0
       fi
     fi
     printf '%s' "$REVIEW_BOT_MIN_EDIT_LAG_SECONDS"
   }

   _comment_is_settled() {
     # Returns 0 if the comment has settled (final form): either has reviewDecision
     # set, or updated_at >= created_at + min_lag. Returns 1 if still in placeholder window.
     local created_at="$1"
     local updated_at="$2"
     local min_lag="$3"
     # If timestamps missing (older API responses), be conservative: treat as settled.
     [[ -z "$created_at" || -z "$updated_at" ]] && return 0
     local created_epoch updated_epoch
     created_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null \
       || date -d "$created_at" +%s 2>/dev/null || echo "0")
     updated_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null \
       || date -d "$updated_at" +%s 2>/dev/null || echo "0")
     [[ "$created_epoch" -eq 0 || "$updated_epoch" -eq 0 ]] && return 0
     # Settled if comment was edited (updated_at > created_at) OR enough time has passed
     # since posting (now - created_at >= min_lag, indicating bot had time to finish).
     local now_epoch
     now_epoch=$(date +%s)
     local age=$((now_epoch - created_epoch))
     local edit_delta=$((updated_epoch - created_epoch))
     if [[ "$edit_delta" -ge "$min_lag" ]] || [[ "$age" -ge "$min_lag" ]]; then
       return 0
     fi
     return 1
   }
   ```

3. **Update `bot_has_real_review()`**: change jq filter to extract `created_at` and `updated_at` alongside body. Require both negative-filter pass AND `_comment_is_settled`. Iterate sources, accumulate the first matching comment per bot, and require settled.

4. **Rename `is_rate_limit_comment` → `is_non_review_comment`** (keep old name as a thin wrapper for any callers).

5. **Update `do_list`** to print `bot: real review`, `bot: not yet (placeholder)`, or `bot: rate-limited (no real review)` based on classification.

6. **Tests** (`tests/test-review-bot-gate-completion-signal.sh`): mock `gh api` via PATH override returning fixtures for each scenario; assert `bot_has_real_review` exit codes.

7. **Document** in `.agents/AGENTS.md` `review_gate` section: add `min_edit_lag_seconds` per-tool/per-repo, with defaults.

### Verification

```bash
shellcheck .agents/scripts/review-bot-gate-helper.sh
shellcheck .agents/scripts/tests/test-review-bot-gate-completion-signal.sh
.agents/scripts/tests/test-review-bot-gate-completion-signal.sh
.agents/scripts/linters-local.sh
# Smoke test against this PR after open
.agents/scripts/review-bot-gate-helper.sh check <PR_NUMBER>
.agents/scripts/review-bot-gate-helper.sh list <PR_NUMBER>
```

## Acceptance Criteria

- [ ] `RATE_LIMIT_PATTERNS` renamed to `NON_REVIEW_PATTERNS` with backwards-compat alias; expanded to include "Review failed", "Review skipped", "closed or merged during review", "Auto reviews are limited"
  ```yaml
  verify:
    method: codebase
    pattern: "NON_REVIEW_PATTERNS=\\("
    path: ".agents/scripts/review-bot-gate-helper.sh"
  ```
- [ ] `_comment_is_settled` and `_get_min_edit_lag` helpers exist and are called from `bot_has_real_review`
  ```yaml
  verify:
    method: codebase
    pattern: "_comment_is_settled"
    path: ".agents/scripts/review-bot-gate-helper.sh"
  ```
- [ ] Test suite passes: `bash .agents/scripts/tests/test-review-bot-gate-completion-signal.sh`
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-review-bot-gate-completion-signal.sh"
  ```
- [ ] `shellcheck` clean on helper and test
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/review-bot-gate-helper.sh .agents/scripts/tests/test-review-bot-gate-completion-signal.sh"
  ```
- [ ] `.agents/AGENTS.md` `review_gate` section documents `min_edit_lag_seconds`
  ```yaml
  verify:
    method: codebase
    pattern: "min_edit_lag_seconds"
    path: ".agents/AGENTS.md"
  ```

## Context & Decisions

- **Hybrid over pure-positive**: Pure positive-signal would miss rate-limit notices (these need negative filter). Pure negative would not defeat two-phase placeholder. Combination is needed.
- **`updated_at` vs `reviewDecision`**: GitHub's formal `reviewDecision` is set only when the bot submits a formal review (CodeRabbit posts comments, not reviews, in most cases). `updated_at > created_at` is the universal cross-bot completion signal.
- **30s default**: CodeRabbit's Phase 1→Phase 2 gap is observed at 90-120s. 30s is conservative enough to avoid blocking fast bots while reliably catching the placeholder window.
- **Conservative on missing timestamps**: If API returns no `updated_at` (older endpoints, errors), treat as settled — better to PASS than block forever.
- **Backwards-compat alias**: `RATE_LIMIT_PATTERNS=("${NON_REVIEW_PATTERNS[@]}")` so external callers/scripts that may reference the old name continue to work.
- **Slot into t2123 schema**: New field is a sibling of `rate_limit_behavior`, no new control plane needed.
- **Non-goals**: Don't change rate-limit branch behavior. Don't add new bots to KNOWN_BOTS. Don't change `do_request_retry` or `do_batch_retry` (they already handle the reclassified state correctly).

## Relevant Files

- `.agents/scripts/review-bot-gate-helper.sh:60-70` — `RATE_LIMIT_PATTERNS`
- `.agents/scripts/review-bot-gate-helper.sh:100-152` — `_get_rate_limit_behavior` (model for `_get_min_edit_lag`)
- `.agents/scripts/review-bot-gate-helper.sh:211-260` — `is_rate_limit_comment` and `bot_has_real_review`
- `.agents/scripts/review-bot-gate-helper.sh:353-415` — `do_check` classification logic
- `.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` — Test harness pattern to follow
- `.agents/AGENTS.md` `review_gate` paragraph (search "review_gate")

## Dependencies

- **Blocked by:** none
- **Blocks:** clean t2093 `CHANGES_REQUESTED` flow on CodeRabbit-reviewed PRs
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Helper file already in context |
| Implementation | 60m | Helper + tests + docs |
| Testing | 20m | Run test suite, smoke against the PR itself |
| **Total** | **~1h35m** | |
