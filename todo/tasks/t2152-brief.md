<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2152: investigate — `needs-consolidation` applied at near-creation time despite single-bot-comment / threshold=2 gate

## Origin

- **Created:** 2026-04-16
- **Session:** opencode:interactive
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** t2144 (consolidation cascade fix, PR #19411 merged)
- **Conversation context:** Discovered while investigating the t2144 multi-runner cascade. Issue #19275 (`review-followup` for PR #19177) was filed at 11:36:17Z and labeled `needs-consolidation` by the alex-solovyev pulse at 13:45:48Z — only **2 hours and 9 minutes** later, with **only one comment** in the timeline at that point (a `github-actions[bot]` origin-worker-protection-notice posted at 11:36:26Z). Two seconds after the label, the consolidation child #19277 was filed.

## What

Identify why `_issue_needs_consolidation` returned 0 (dispatch gate passed) when the only candidate comment was a bot-authored notice that the current `.user.type != "Bot"` filter at `pulse-triage.sh:323` should have excluded. The current code (post-t2144) has both the bot-type filter AND the t2144 HTML-comment-prefix filter — neither should let a single `github-actions[bot]` comment count. Yet the production timeline shows the dispatch fired.

## Why

Three plausible mechanisms exist, each with different fix shapes:

1. **`.user.type != "Bot"` is unreliable.** GitHub's `users` API field returns `Bot` for App-installed users (`github-actions[bot]`) and `User` for human accounts, but the historical contract on the `comments` endpoint may differ — particularly for `github-actions` posting via `secrets.GITHUB_TOKEN`. If the field returns `User` for some bots, the entire filter is bypassed.
2. **Body content is being counted somewhere.** `_issue_needs_consolidation` only reads comments, but a different code path (`_reevaluate_consolidation_labels`, `_backfill_stale_consolidation_labels`, or even an older issue-sync hook) might be including the issue body in its substantive-content estimate. The `review-followup` body is structurally similar to substantive review feedback (long, contains `<details>` with quoted bot text).
3. **Race-window self-counting.** If the dispatch flow posts its `## Issue Consolidation Dispatched` comment BEFORE final label-add, and another runner re-evaluates the gate in the same window, it could see 2 comments (the origin-protection notice + its own dispatch comment) and pass the gate retroactively. The 2-second gap between labeling (13:45:48Z) and the dispatch comment (13:45:50Z) is consistent with this.

The label timeline also shows ping-pong at 18:37:32Z (unlabeled) → 18:37:43Z (re-labeled) — `_reevaluate_consolidation_labels` clears stale labels and `_backfill_stale_consolidation_labels` re-adds them. If the underlying gate is unstable, this loop is the visible artefact.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Investigation with no known mechanism. Three competing hypotheses, each requires different diagnostic steps. `_issue_needs_consolidation` is shared by multiple callers; changing it without understanding the actual trigger risks breaking working paths. Not a copy-the-pattern fix.

## How

### Files to investigate

- `.agents/scripts/pulse-triage.sh:255-330` — `_issue_needs_consolidation` (the gate)
- `.agents/scripts/pulse-triage.sh:344-380` — `_reevaluate_consolidation_labels` (re-checks all labeled issues)
- `.agents/scripts/pulse-triage.sh:854-910` — `_dispatch_issue_consolidation` (label-then-comment ordering)
- `.agents/scripts/pulse-triage.sh:916-985` — `_backfill_stale_consolidation_labels` (the ping-pong source)
- `.agents/scripts/issue-sync-helper.sh` — search for any path that adds `needs-consolidation` outside `pulse-triage.sh`

### Investigation steps

1. **Reproduce the bot-type contract.** Run `gh api repos/marcusquinn/aidevops/issues/19275/comments --jq '.[] | {login: .user.login, type: .user.type}'` and confirm whether `github-actions[bot]` returns `Bot` or `User`. If `User`, the filter is broken — switch to a name-pattern match (`(login | endswith("[bot]") or login == "github-actions")`) instead of relying on `.user.type`.
2. **Audit the body-vs-comments contract.** `grep -n "issues/.*/comments" .agents/scripts/*.sh` and `grep -n '\.body' .agents/scripts/pulse-triage.sh` — verify no consolidation gate path includes the issue body in its count.
3. **Audit dispatch-comment race.** Add timestamps to a debug pulse run; measure the gap between `gh issue edit --add-label needs-consolidation` and the `## Issue Consolidation Dispatched` comment-post. If <5s, multiple runners can interleave their gate evaluations.
4. **Find any non-pulse path that adds the label.** `grep -rn 'add-label "needs-consolidation"\|--label.*needs-consolidation' .agents/scripts/` — anything outside `pulse-triage.sh` or the labels-config script is a discovery.

### Verification

- A regression test in `tests/test-consolidation-dispatch.sh` simulating a single `github-actions[bot]` comment on an empty parent must return `_issue_needs_consolidation` = 1 (no dispatch).
- Re-process #19275 against the fixed code with a dry-run flag and confirm the gate returns 1.

## Acceptance criteria

- [ ] Root cause identified with code-line evidence (one of the three hypotheses, or a fourth surfaced during investigation)
- [ ] Fix targeted at the actual mechanism (bot-type filter, body-leak, race-window, or other)
- [ ] Regression test added that fails against the buggy code path and passes against the fix
- [ ] Manual re-evaluation against #19275 confirms the gate now returns 1 (no dispatch)
- [ ] No regression on existing `tests/test-consolidation-dispatch.sh` (currently 12/12)

## Out of scope

- Multi-runner coordination (separate task: t2151 / Phase B)
- Phase A single-runner cascade fixes (done in t2144 / PR #19411)
- The `_reevaluate` ↔ `_backfill` ping-pong loop unless investigation surfaces it as the root cause

## PR Conventions

Leaf issue (single PR delivering the fix + regression test). Use `Resolves #<issue-number>` in the PR body.

Ref #19347 (Phase A — t2144)
