<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2686: quality-debt NMR trap — broaden trust check + teach sig detector about `source:review-feedback`

ref: GH#20299

## Session Origin

Interactive session triggered by user request (2026-04-21). Ten `source:review-feedback` quality-debt issues on `awardsapp/awardsapp` (#2572–2578, #2583–2585) were stuck in NMR purgatory despite being filed by the maintainer's own pulse against PRs authored by an admin collaborator (`alex-solovyev`). Root-cause tracing surfaced two compounding bugs — the fix here addresses both.

## What

Two surgical fixes to the quality-debt creation and auto-approval pipelines, plus tests.

1. `quality-feedback-issues-lib.sh`: replace strict `pr_author == maintainer` equality with a collaborator-trust check. An issue is "maintainer-equivalent" (`is_maintainer_pr="true"`) when the PR author has `admin` or `maintain` permission on the repo — the same trust bar that `pulse-merge.sh` already uses for auto-merge gates (t2411 criterion 2, t2449 criterion 2).

2. `pulse-nmr-approval.sh`: extend `_nmr_application_has_automation_signature` to recognise `source:review-feedback` (the label that `quality-feedback-helper.sh` stamps on its issues) in addition to the existing `source:review-scanner` signature.

3. Tests covering both paths.

## Why

**Bug 1 — creation path (`quality-feedback-issues-lib.sh:570-586`).** The lib looks up a single `maintainer` string from `repos.json` (or slug-owner fallback) and demands strict equality. On a repo with multiple admin collaborators — the common case for any team larger than one — every quality-debt issue generated from a non-`maintainer` collaborator's PR gets NMR slapped on at creation, even though the PR itself was already trusted enough to merge into `main`. The rest of the framework standardised on `authorAssociation ∈ {OWNER, MEMBER}` or `permission ∈ {admin, maintain}` as the trust bar (t2411 auto-merge, t2449 worker-briefed auto-merge, maintainer-gate.yml). This lib diverged.

**Bug 2 — auto-approve path (`pulse-nmr-approval.sh:281-321`).** `_nmr_application_has_automation_signature` only looks for `source:review-scanner` (emitted by `post-merge-review-scanner.sh`). The `quality-feedback-helper.sh` sibling emits `source:review-feedback`. Result: when the pulse applies NMR at creation via Bug 1, it cannot auto-clear it later because its own signature is invisible to the detector. `_nmr_applied_by_maintainer` then classifies the label application as a "manual hold" and `auto_approve_maintainer_issues` skips the issue forever.

Together, Bug 1 applies NMR to trusted-collaborator quality-debt; Bug 2 guarantees it never comes off. Net effect: manual `sudo aidevops approve issue <N>` required per issue, multiplied by team size × PR frequency × file count per PR. The 10 stuck issues on `awardsapp/awardsapp` are the symptom; the structural problem is baked into the pipeline.

**Downstream gate awareness.** `issue_was_ever_nmr` reads the immutable GitHub timeline, so even after this fix lands, the 10 existing stuck issues still fail `issue_has_required_approval` at PR-merge time. Batch cryptographic approval (`sudo aidevops approve issue <N>`) is the one-shot cleanup that clears all three concerns at once: records the signed marker, removes NMR, adds `auto-dispatch`. Listed separately under "How" step 5.

## How

### Files Scope

- `.agents/scripts/quality-feedback-issues-lib.sh`
- `.agents/scripts/pulse-nmr-approval.sh`
- `.agents/scripts/tests/test-pulse-nmr-automation-signature.sh`
- `.agents/scripts/tests/test-quality-feedback-trust-bar.sh`
- `todo/tasks/t2686-brief.md`
- `TODO.md`

### Step 1 — `quality-feedback-issues-lib.sh`: broaden trust check

In `_find_quality_debt_in_pr_data` (around line 570-586), replace the single-maintainer equality with:

1. Keep the existing `repos.json .maintainer` lookup as a first-pass fast path (avoids a `gh api` call when the author IS the single maintainer — still the common case for solo-maintainer repos).
2. If the fast path doesn't match, call `gh api repos/{slug}/collaborators/{pr_author}/permission --jq .permission 2>/dev/null`. If the result is `admin` or `maintain`, set `is_maintainer_pr="true"`.
3. Fail-closed on API errors: if the `gh api` call fails (network, auth, unknown user), leave `is_maintainer_pr="false"` and let NMR apply — the approval gate is the correct default for untrusted authorship, and an API blip is not a trust signal.
4. Emit a single `[INFO]` log line when the broadened path matches so the decision is visible in scan output.

Keep `is_maintainer_pr` as the local-variable name to minimise diff churn; the SEMANTICS expand but the identifier stays stable and all three call sites already consume it as a boolean gate.

### Step 2 — `pulse-nmr-approval.sh`: extend sig detector

In `_nmr_application_has_automation_signature` (around line 281-321), extend the label-based detection branch (currently matching `review-followup` or `source:review-scanner`) to ALSO match `source:review-feedback`. One added case in the existing `jq` `map(select(...))` expression. No new API calls — the label set is already fetched for the scanner detection.

Also extend the comment-based detection regex to match `quality-feedback-helper.sh` as a secondary marker string, for defence in depth against issues where the label was stripped but the provenance comment remains.

### Step 3 — Tests

Extend `test-pulse-nmr-automation-signature.sh`:
- New case `test_source_review_feedback_label_matches_signature`: synthesise an issue with `source:review-feedback` label, call `_nmr_application_has_automation_signature`, assert exit 0.
- New case `test_quality_feedback_helper_comment_matches_signature`: synthesise an issue with a comment containing `quality-feedback-helper.sh`, assert exit 0.

New file `test-quality-feedback-trust-bar.sh`:
- Mock `gh pr view` author as the single maintainer → `is_maintainer_pr=true`, no `gh api` call.
- Mock `gh pr view` author as a non-maintainer + mock `gh api collaborators/{user}/permission` → `admin` → `is_maintainer_pr=true`.
- Same but permission `write` → `is_maintainer_pr=false`.
- Same but `gh api` returns 404 → `is_maintainer_pr=false` (fail-closed).

Both tests run under the existing `./tests/` harness. `shellcheck` clean.

### Step 4 — TODO.md

Add entry under `## In Progress`:

```
- [ ] t2686 quality-debt NMR trap: broaden trust check + teach sig detector source:review-feedback ref:GH#20299 #bug #auto-dispatch started:2026-04-21
```

### Step 5 — Cleanup (separate terminal, user-run)

After this PR merges, run in a separate terminal (requires sudo/password):

```bash
for n in 2572 2573 2574 2575 2576 2577 2578 2583 2584 2585; do
  sudo aidevops approve issue "$n" awardsapp/awardsapp
done
```

Each invocation: posts the signed `<!-- aidevops-signed-approval -->` marker (immortal approval for the ever-NMR gate), removes `needs-maintainer-review`, adds `auto-dispatch`, assigns the approving maintainer. Pulse will dispatch workers on the next cycle.

## Acceptance

1. `awardsapp/awardsapp` PR authored by `alex-solovyev` (or any admin/maintain collaborator) generates a quality-debt issue WITHOUT `needs-maintainer-review` — matches behaviour for maintainer-authored PRs.
2. If for some reason NMR is later applied to a `source:review-feedback` issue (e.g. via a circuit-breaker trip — unchanged, still preserves NMR correctly), the next pulse cycle's `auto_approve_maintainer_issues` DOES recognise it as automation-default and auto-clear it. This is verified by the new test case.
3. Existing `test-pulse-nmr-automation-signature.sh` cases still pass (no regression on `source:review-scanner`, `review-followup`, and breaker-trip handling).
4. `shellcheck` clean on all three edited files.
5. Batch crypto-approve commands (Step 5) clear the 10 stuck issues without manual editing.

## Context

- Canonical AGENTS.md reference: "Auto-merge timing (t2411)" criterion 2 and "Auto-merge timing (t2449)" criteria 2-3 — both already use `permission ∈ {admin, maintain}` or `authorAssociation ∈ {OWNER, MEMBER}` as the trust bar. This brings `quality-feedback-issues-lib.sh` into alignment.
- Related memory: "Maintainer-authored research tasks MUST use `#parent` (t2211)" — that lesson covered a different failure mode of the NMR-approval path (auto-approve stripping NMR and forcing auto-dispatch on research tasks). This task covers the inverse: auto-approve FAILING to strip NMR on legitimate dispatchable issues.
- Related incident: GH#19756 infinite-loop (t2386) — informed the current split-semantics architecture of `_nmr_applied_by_maintainer`. The fix here EXTENDS the creation-default signature set; it does NOT touch the breaker-trip branch. Breaker trips still preserve NMR. Regression test covers both branches.

## Tier Checklist

- [x] Affects >2 files (3 source files + 2 tests + TODO.md + brief)
- [x] Requires judgement (trust-model boundary decision; which collaborator permissions count as "maintainer-equivalent")
- [x] Test cases require synthesis (mocking `gh api` permission endpoint)

→ tier:standard (Sonnet). Already implementing interactively, not dispatched.

## Files Scope

- .agents/scripts/quality-feedback-issues-lib.sh
- .agents/scripts/pulse-nmr-approval.sh
- .agents/scripts/tests/test-pulse-nmr-automation-signature.sh
- .agents/scripts/tests/test-quality-feedback-trust-bar.sh
- todo/tasks/t2686-brief.md
- TODO.md
