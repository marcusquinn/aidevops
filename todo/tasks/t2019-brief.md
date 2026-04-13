<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2019 — fix(pulse-triage): worker produces headerless 60-80KB output

- **Status:** in-progress
- **Tier:** `tier:reasoning`
- **Issue:** GH#18482
- **Session origin:** follow-up to t2016 (PR #18476, released v3.7.3)
- **Worktree:** `~/Git/aidevops-bugfix-t2019-triage-headerless-output`
- **Branch:** `bugfix/t2019-triage-headerless-output`

## Origin

- Parent session: t2016 (PR #18476, released v3.7.3) made triage failures
  maintainer-visible via escalation comments. This task is the follow-up that
  fixes the underlying worker quality problem so the escalation path is rarely
  hit.
- Evidence: `~/.aidevops/logs/pulse-wrapper.log` contains three consecutive
  failures for #18428 on 2026-04-12:
  - Attempt 1: 72,233 chars, no `## Review` header
  - Attempt 2: 80,568 chars, no `## Review` header
  - Attempt 3: 62,198 chars, raw sandbox output (infra markers)
- The safety filter correctly suppressed all three. The bug is that the worker
  is producing output in that shape in the first place.

## What

Investigate and fix the root cause of the triage-review worker producing
massive (60-80KB) outputs without a `## Review` header. The worker is a
sandboxed headless agent run via `headless-runtime-helper.sh run` with the
prompt from `_build_triage_review_prompt()` and the agent instructions at
`.agents/workflows/triage-review.md`. Something in that pipeline is letting
the worker ramble for tens of kilobytes before (or instead of) producing the
`## Review` section the post-processor expects.

## Why

The escalation path shipped in t2016 is a safety net, not a success path.
Every time the worker output is suppressed:

1. The issue sits in the NMR queue longer than necessary
2. Opus/Sonnet tokens are burned on output that gets discarded
3. The retry cap eventually fires, writing the cache and requiring manual
   maintainer intervention
4. A visible escalation comment is posted (good, but it's a failure signal —
   not a review)

Each suppressed attempt at 60-80K chars × opus pricing × 2 retries ×
frequency of NMR issues is a measurable token waste. Fixing the worker so it
produces a clean `## Review` section on the first attempt recovers that cost
and shortens time-to-triage.

## How (Approach)

### Step 1 — Capture a real failure repro

Don't guess. Reproduce the failure with a known-stuck issue so the actual
60-80KB output is in hand before modifying anything.

```bash
# Find any still-open NMR issue with no triage comment yet
gh issue list --repo marcusquinn/aidevops \
  --label needs-maintainer-review --state open --json number,title

# Delete its cache entry to force a retry on next pulse cycle
rm -f ~/.aidevops/.agent-workspace/tmp/triage-cache/marcusquinn_aidevops-<N>.hash

# Run the dispatch function directly with a capture — DO NOT run a full pulse
# cycle. Source the modules and invoke _dispatch_triage_review_worker with a
# hand-rolled prefetch prompt so the raw worker output is captured:
source ~/.aidevops/agents/scripts/shared-constants.sh
source ~/.aidevops/agents/scripts/pulse-ancillary-dispatch.sh
LOGFILE=/tmp/t2019-debug.log \
  _build_triage_review_prompt <N> marcusquinn/aidevops ~/Git/aidevops
# tee the prefetch file and run headless-runtime-helper.sh run manually to
# capture raw output for offline analysis
```

Save raw output to a file — it is the evidence artifact for every hypothesis
test below.

### Step 2 — Hypothesis tree (cheapest first)

1. **Hypothesis A — agent file is too loose.**
   Read `.agents/workflows/triage-review.md`. Does it (a) demand the
   `## Review` header be the first output, (b) forbid preamble / thinking /
   exploration, (c) cap output length? If any are missing, tighten the prompt.
   Cheap fix. Verify by re-running Step 1 with the new agent file.
2. **Hypothesis B — prefetch prompt is too large.**
   `_build_triage_review_prompt()` at
   `.agents/scripts/pulse-ancillary-dispatch.sh:166-253` concatenates
   `ISSUE_METADATA`, `ISSUE_BODY`, `ISSUE_COMMENTS`, `PR_DIFF` (first 500
   lines), `PR_FILES`, `RECENT_CLOSED` (30 titles), `GIT_LOG`. For an NMR
   issue with long comments (exactly when triage is most valuable), this is
   tens of KB of input. Check whether the 60-80KB output is the model
   echoing / summarising the input rather than producing a review.
3. **Hypothesis C — headless runtime leaks sandbox boot lines to stdout.**
   Attempt 3 was raw sandbox output — this can happen. Check whether the
   other two attempts also had partial infra noise that escaped detection
   (the current `has_infra_markers` regex may not cover all runtime noise
   patterns). Run `headless-runtime-helper.sh run` in isolation with a
   trivial prompt and inspect stdout for non-model output.
4. **Hypothesis D — sandbox model does long tool explorations.**
   The agent file restricts tools to Read/Glob/Grep, but if the model decides
   to read 50 files before writing the review, that is where the byte count
   comes from. The fix is an explicit "do not explore the codebase; use only
   the prefetched context" instruction.
5. **Hypothesis E — output truncation inverted.**
   Check whether the output file is captured correctly — if something
   truncates or reverses order (unlikely but worth 30s to verify), the
   `## Review` header might actually be there but past the cut-off.

### Step 3 — Pick the primary fix and add belt-and-suspenders

Whichever hypothesis wins, also add pre-dispatch output-shape validation so
future drift is caught earlier:

- Extend the safety filter in `_dispatch_triage_review_worker` to log the
  first 500 chars of any suppressed output (redacted for infra markers) to a
  separate debug log so future suppressions leave evidence for diagnosis
  without requiring live capture.
- Add an output-length ceiling (e.g., suppress anything >20KB as
  "suspiciously long — worker likely malfunctioning") so the retry cap isn't
  wasted on 3 consecutive 80KB blobs.

## Files to Modify (candidates — refine based on hypothesis)

- EDIT: `.agents/workflows/triage-review.md` — tighten agent instructions
  (primary candidate)
- EDIT: `.agents/scripts/pulse-ancillary-dispatch.sh:166-398` — trim prefetch
  prompt, add shape validation
- NEW: `.agents/scripts/tests/test-triage-output-shape.sh` — assert
  suppression behaviour on synthetic outputs

## Reference Patterns

- Agent file format: other files in `.agents/workflows/` — YAML frontmatter
  with `tools:` restrictions.
- Headless runtime invocation:
  `.agents/scripts/pulse-ancillary-dispatch.sh:366-372`.
- Test harness style:
  `.agents/scripts/tests/test-triage-failure-escalation.sh` (from t2016 —
  uses mocked `gh`).
- Signature footer: `gh-signature-helper.sh footer`.

## Verification

```bash
# 1. Unit tests for any new safety filter logic
.agents/scripts/tests/test-triage-output-shape.sh

# 2. Regression — t2016 escalation tests must still pass
.agents/scripts/tests/test-triage-failure-escalation.sh

# 3. Live smoke test — delete one stale cache, run pulse once, assert a real
#    ## Review comment is posted on the target issue within 2 cycles
rm -f ~/.aidevops/.agent-workspace/tmp/triage-cache/marcusquinn_aidevops-<N>.hash
/usr/bin/env bash ~/.aidevops/agents/scripts/pulse-wrapper.sh --once
gh issue view <N> --repo marcusquinn/aidevops --json comments \
  --jq '.comments[] | select(.body | startswith("## ")) | .body' | head

# 4. ShellCheck clean
shellcheck .agents/scripts/pulse-ancillary-dispatch.sh
```

## Acceptance Criteria

- [ ] Root cause identified and documented in the PR description with
  evidence (captured raw output file + hypothesis trace).
- [ ] At least one NMR issue that was previously producing >20KB no-header
  output now produces a valid `## Review` comment on the first attempt,
  verified via live pulse run.
- [ ] New shape-validation path in `_dispatch_triage_review_worker` catches
  suspiciously-long outputs with a distinct log line (separate from the
  existing no-review-header path) so future regressions are diagnosable
  without re-running captures.
- [ ] Existing `test-triage-failure-escalation.sh` passes unchanged (no t2016
  regression).
- [ ] ShellCheck clean on any modified file.
- [ ] PR body cites the `~/.aidevops/logs/pulse-wrapper.log` evidence from
  the t2016 session (72233 / 80568 / 62198 char attempts on #18428) as the
  original bug report.

## Context & Decisions

- **Do not remove the safety filter.** The current filter is correct —
  suppressing infra markers and headerless output protects the repo from
  leaked sandbox data. The fix must make the worker produce good output,
  not weaken the filter.
- **Do not expand `TRIAGE_MAX_RETRIES`.** t2014 cut it from 3 to 1 to
  eliminate lock/unlock churn. Increasing it would regress that fix and
  multiply token cost on every failure.
- **Prefer prompt fixes over code fixes.** An agent file edit is low-risk,
  idempotent, and easy to roll back. Code fixes in the dispatch worker
  should be reserved for the shape-validation safety net, not the primary
  solution.
- **Don't investigate in parallel with live pulse cycles.** Disable the
  pulse while capturing raw output — concurrent cycles will eat cache
  entries and make repro non-deterministic.
- **Token budget:** research + fix + tests should fit inside the reasoning-
  tier budget. If hypothesis testing blows past 1h without a lead, that is
  a signal to escalate for pair debugging rather than spinning further.

## Relevant Files

- `.agents/workflows/triage-review.md` — the agent file the sandboxed
  worker loads
- `.agents/scripts/pulse-ancillary-dispatch.sh:166-398` —
  `_build_triage_review_prompt` + `_dispatch_triage_review_worker` (full
  dispatch pipeline)
- `.agents/scripts/headless-runtime-helper.sh` — the runtime that launches
  the sandboxed agent
- `~/.aidevops/logs/pulse-wrapper.log` — historical failure evidence for
  #18428
- `.agents/scripts/tests/test-triage-failure-escalation.sh` — t2016
  regression guard
- `todo/tasks/t2016-brief.md` — predecessor brief with full root-cause
  analysis

## Dependencies

- Blocked by: none
- Blocks: the triage-review pipeline being trustworthy on its own. Every
  NMR issue currently benefits from the t2016 escalation safety net but
  still costs tokens and latency.
- Related: t2016 (escalation comment), t1916 (triage dispatch gate
  removal), t2014 (retry cap reduction).

## Estimate Breakdown

| Phase              | Time    | Notes                                      |
| ------------------ | ------- | ------------------------------------------ |
| Repro capture      | 30m     | One NMR issue, save raw output file        |
| Hypothesis testing | 1-2h    | Start with agent file, escalate the tree   |
| Primary fix        | 30-60m  | Prompt edit + shape validation belt        |
| Tests              | 30m     | New test file + regression checks          |
| Live smoke test    | 30m     | Delete cache, run one pulse, verify comment|
| Total              | 3-4h    | reasoning tier — budget accordingly        |
