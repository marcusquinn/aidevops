---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2016: fix(pulse-triage): surface triage failures to maintainer when retry cap is hit

## Origin

- **Created:** 2026-04-13
- **Session:** opencode:interactive
- **Created by:** marcusquinn (human, interactive session)
- **Conversation context:** While manually reviewing issue #18428 we noticed the
  automated triage worker never produced a `## Review` comment, yet the content-hash
  cache was written and the issue was then silently skipped on every subsequent pulse
  cycle. Log investigation (`~/.aidevops/logs/pulse-wrapper.log`) showed three
  consecutive failures for #18428 (72KB/80KB/62KB output — "no review header" twice
  and "raw sandbox output" once), followed by `Triage retry cap reached ... caching
  hash to stop lock/unlock loop`. The maintainer had zero visible signal — no
  `triage-failed` label, no escalation comment, only buried log lines.

## What

When `dispatch_triage_reviews` hits the `TRIAGE_MAX_RETRIES` cap and writes the cache
to break the lock/unlock loop, post a structured, idempotent **maintainer escalation
comment** on the issue so the failure is visible in the issue timeline. Also fix
`gh_create_label`-style provisioning so the `triage-failed` label is actually created
in the repo before being added (today the add silently fails on repos without the
label, but the log unconditionally claims success).

Out of scope: improving the triage-review worker prompt so it stops producing huge
headerless outputs — that is a worker-quality fix tracked separately.

## Why

The whole point of triage dispatch (t1916) was to give the maintainer a head start on
reviewing `needs-maintainer-review` issues. When triage silently fails, three things
break:

1. The maintainer has no signal that automation even tried — they must manually
   re-discover the issue in the NMR queue.
2. The content-hash cache is now permanent — the pulse will `triage dedup: skipping`
   on every cycle forever (until a new comment changes the hash).
3. The `triage-failed` label was the designed observability channel but was never
   actually created in the repo, so the escalation path was a dead letter.

Evidence of the impact: #18428 sat for ~2h with three failed triage attempts, no
visible signal, and the only reason the maintainer intervened was because a human
(`/review-issue-pr`) was run against it manually.

## Tier

`tier:standard`

**Tier rationale:** Two-file touch (dispatch + test), clear cause chain, but the
escalation comment design needs judgment about idempotency, content, and when to
fire. Haiku would miss the idempotency marker and the "test with mocked gh" pattern.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-ancillary-dispatch.sh:145-250` — in
  `_dispatch_triage_review_worker`:
  - Capture the suppression reason (no-header / raw-sandbox / no-output) into a
    local `failure_reason` variable so it can be surfaced in the escalation comment.
  - Replace the unconditional `gh issue edit --add-label "triage-failed"` with a
    wrapper that (a) calls `gh label create --force` to ensure the label exists,
    (b) checks whether the add command succeeded, (c) only logs "Added" on success.
  - When `_triage_increment_failure` signals "cap hit", call a new helper
    `_post_triage_escalation_comment` before writing the cache.
- `NEW: .agents/scripts/tests/test-triage-failure-escalation.sh` — unit tests using
  the test-pulse-wrapper-ever-nmr-cache.sh style (mocked `gh`, temp $HOME, marker
  files to assert call behaviour).

### Reference patterns

- `gh label create --force` idempotent pattern: `issue-sync-helper.sh:203-206`
  (`gh_create_label`).
- Test harness style: `.agents/scripts/tests/test-pulse-wrapper-ever-nmr-cache.sh`
  (mocked `gh`, `setup_test_env`/`teardown_test_env`, `print_result` helper).
- Idempotent comment marker pattern: `scripts/commands/pulse.md` dispatch comments
  use `<!-- MERGE_SUMMARY -->`, `<!-- ops:start/end -->`. New marker:
  `<!-- triage-escalation -->`.

### Implementation Steps

1. Add helper `_post_triage_escalation_comment issue_num repo_slug failure_reason
   attempts output_chars`:
   - First check if a comment with `<!-- triage-escalation -->` already exists on
     the issue via `gh api repos/$slug/issues/$num/comments`. If found, return 0
     without posting (idempotent).
   - Build a structured markdown body containing: what failed, attempt count, last
     failure reason, output size, how to recover (remove `triage-failed` label or
     delete cache hash file). Include the `<!-- triage-escalation -->` marker at
     the top.
   - Append the standard signature footer via `gh-signature-helper.sh footer`
     (passing `--issue $slug#$num`).
   - Post with `gh issue comment`. Log success or failure.

2. Add helper `_ensure_triage_failed_label repo_slug`:
   - `gh label create "triage-failed" --repo "$repo_slug" --color "E11D21"
     --description "Automated triage could not produce a review — needs manual
     attention" --force 2>/dev/null || true`.

3. Refactor the label-add block (lines 224-231) in `_dispatch_triage_review_worker`:
   - Track `failure_reason` throughout the suppression branches (lines 202-220).
   - On `triage_posted=false`, call `_ensure_triage_failed_label` first, then run
     the add with explicit exit code capture.
   - Only log "Added triage-failed label" when the add command exit code was 0.

4. In the cache-update block (lines 236-247), in the `_triage_increment_failure`
   branch, call `_post_triage_escalation_comment` before `_triage_update_cache`.

5. Write `test-triage-failure-escalation.sh` with at least these assertions:
   - `_post_triage_escalation_comment` writes the marker body via mocked `gh issue
     comment`.
   - Repeated calls are no-ops when the marker is already present (reads mock
     comment list).
   - `_ensure_triage_failed_label` invokes `gh label create --force`.
   - Structured body contains the failure reason, attempt count, and recovery
     instructions.

### Verification

```bash
shellcheck .agents/scripts/pulse-ancillary-dispatch.sh
.agents/scripts/tests/test-triage-failure-escalation.sh
# Repeat runs of .agents/scripts/tests/test-pulse-wrapper-ever-nmr-cache.sh
# to confirm we haven't regressed the adjacent cache code path.
```

## Acceptance Criteria

- [ ] `_post_triage_escalation_comment` helper exists and is called when
      `_triage_increment_failure` signals cap hit.
  ```yaml
  verify:
    method: bash
    run: "grep -q '_post_triage_escalation_comment' .agents/scripts/pulse-ancillary-dispatch.sh"
  ```
- [ ] The escalation comment uses an HTML marker for idempotency.
  ```yaml
  verify:
    method: bash
    run: "grep -q 'triage-escalation' .agents/scripts/pulse-ancillary-dispatch.sh"
  ```
- [ ] `_ensure_triage_failed_label` is called before every `--add-label
      triage-failed` invocation.
  ```yaml
  verify:
    method: bash
    run: "awk '/_ensure_triage_failed_label/,/add-label \"triage-failed\"/' .agents/scripts/pulse-ancillary-dispatch.sh | grep -q 'add-label'"
  ```
- [ ] New test file passes.
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tests/test-triage-failure-escalation.sh"
  ```
- [ ] Existing NMR cache test still passes (no regression).
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tests/test-pulse-wrapper-ever-nmr-cache.sh"
  ```
- [ ] ShellCheck clean on the modified file.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-ancillary-dispatch.sh"
  ```
- [ ] The `triage-failed` label is provisioned in the `marcusquinn/aidevops` repo
      after the first pulse cycle that runs the patched code (manual verification
      post-merge).

## Context & Decisions

- **Why not fix worker output quality in the same PR?** The observability gap is
  the blocker — without it, every future worker regression will silently fail. Worker
  quality (prompt tuning, output validation pre-post) is a bigger, more judgment-heavy
  change that deserves its own investigation and PR.
- **Why post a comment instead of relying on the label?** Labels are quiet —
  notifications happen on comment, not label. Also the label currently does not
  exist in the repo at all, so it was never a working signal. A comment creates an
  issue-timeline event the maintainer cannot miss.
- **Idempotency via HTML marker, not label-presence:** cache may be cleared and
  retries attempted; the label may be manually removed. The durable signal is the
  comment body itself, scanned for a known marker.
- **Why not block cache write entirely on failure?** t2014 just reduced
  `TRIAGE_MAX_RETRIES` to 1 specifically to break the lock/unlock churn on persistent
  failures. The cache IS the right answer — we just also need a loud signal when it
  was written via the failure path.
- **Structured escalation body content:** include failure reason, attempt count,
  byte count, and recovery steps (remove label, delete hash file, or re-run
  `/review-issue-pr` manually).

## Relevant Files

- `.agents/scripts/pulse-ancillary-dispatch.sh` — dispatch, label, cache logic
- `.agents/scripts/issue-sync-helper.sh:203-206` — `gh_create_label` reference
- `.agents/scripts/tests/test-pulse-wrapper-ever-nmr-cache.sh` — test harness style
- `.agents/scripts/gh-signature-helper.sh` — signature footer helper
- `~/.aidevops/logs/pulse-wrapper.log` — historical evidence of #18428 failures
- `~/.aidevops/.agent-workspace/tmp/triage-cache/marcusquinn_aidevops-18428.hash` —
  the stale cache file that locked #18428 out of triage

## Dependencies

- **Blocked by:** none
- **Blocks:** future regressions of the triage pipeline from going unnoticed
- **Related:** t1916 (triage dispatch), t2014 (retry cap reduction), t1934 (locking)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research | 30m | Done in parent session (log analysis, code trace) |
| Implementation | 45m | Two helpers, refactor label block, escalation comment |
| Tests | 30m | New test file, mock `gh` interactions |
| Verification | 15m | Shellcheck, run tests, manual repro check |
| **Total** | **2h** | |
