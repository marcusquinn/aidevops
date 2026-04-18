<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2247: full-loop-helper --admin fallback — emit PR comment + audit log entry on silent bypass

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19771
**Tier:** standard (NOT auto-dispatch — signal-vs-silent design decision)

## What

`full-loop-helper.sh::_merge_execute` at line 989 silently falls back to `gh pr merge --admin` when branch protection blocks a plain merge (lines 1033-1046). The fallback is documented in comments (GH#18538) and logs one `print_info` line to stdout — but does NOT:

1. Post a comment on the PR recording that admin-merge was used and WHY
2. Write to the tamper-evident audit log (`audit-log-helper.sh`)
3. Apply a filterable label for cross-PR aggregation

The stdout `print_info` is audit-only-via-session-log-file. Once the session ends, there is no cross-session evidence that this particular PR bypassed the review-bot-gate.

## Why

The `--admin` fallback is the correct design when branch protection legitimately blocks a merge that should proceed (CodeRabbit rate-limited, reviewer unavailable, etc.). But "legitimate bypass" and "review-bot-gate silently failed open" look identical at the PR level.

Concrete sequence observed on PR #19764 (bonus find chain):

1. CodeRabbit skipped auto-review (config label-filter issue — sibling t2246 / GH#19770)
2. No `APPROVED` review from any bot → `reviewDecision: REVIEW_REQUIRED`
3. Branch protection blocked plain merge
4. Helper fell back to `--admin` → merged successfully
5. No audit trail on the PR. Only a log line in the terminal session.

Without t2246 fixed, this would repeat on every maintainer PR, silently degrading the gate across the framework. With t2246 fixed, bypass will still happen occasionally (rate-limit, bot outage) — and when it does, transparency matters.

## How

### Files to modify

- **EDIT:** `.agents/scripts/full-loop-helper.sh:1030-1042` (the `--admin` fallback branch in `_merge_execute`)
- **EXTEND or NEW:** `.agents/scripts/tests/test-full-loop-merge.sh`

### Implementation

After a successful `--admin` fallback (after line 1037 `print_success "PR #${pr_number} merged with --admin fallback"`), add three artifacts:

1. **PR comment** describing why admin merge was used:
   - Exact branch-protection error text (already captured in `$_merge_out`)
   - What bots were expected to approve (CodeRabbit, Gemini) and whether they reviewed
   - Remediation note: "If unintended, revert with `gh pr revert` and investigate why review bots did not approve"
   - Signature footer from `gh-signature-helper.sh`
   - Use `<!-- ops:start/end -->` markers per `prompts/build.txt` section 8d (audit-trail skip when reading)

2. **Audit log entry** via `audit-log-helper.sh log merge-admin-fallback "PR #${pr_number} in ${repo} — ${merge_method} — reason: <parsed-error-category>"`. Canonical pattern per `reference/audit-logging.md`.

3. **`admin-merge` label** applied to PR: `gh pr edit ${pr_number} --repo ${repo} --add-label admin-merge` — makes admin-merged PRs filterable for weekly/monthly audits (`gh pr list --label admin-merge`).

### Reference patterns

- Audit log caller pattern: grep `.agents/scripts/` for `audit-log-helper.sh log` invocations
- PR comment pattern: existing merge-summary comment in `full-loop-helper.sh` (around line 846-854)
- Signature footer: `gh-signature-helper.sh footer --model <model-id>`

### Preserve existing semantics

- **Explicit** `--admin` / `--auto` callers are NOT a fallback — no signaling. The existing `has_admin`/`has_auto` sentinel-check at line 1033 already gates the fallback; only ADD signaling inside that branch (lines 1033-1046).
- The `print_info` + `print_success` stdout lines stay — they're useful for interactive debugging.

### Verification

- Unit test: stub `gh pr merge` to return branch-protection error on first call, success on second call with `--admin`; assert PR comment is posted, audit log entry written, `admin-merge` label applied.
- Unit test: explicit `--admin` caller → no extra signaling (back-compat).
- Smoke test: trigger a real admin fallback on a test branch (artificially remove review bot config); verify all three artifacts present.
- `shellcheck .agents/scripts/full-loop-helper.sh` clean.

### Why NOT auto-dispatch

Design decision with visible side effects: every admin-fallback PR gets a comment (transparency vs. comment noise). Maintainer picks the tradeoff. My recommendation: signal them — the audit trail is worth the comment noise, and comments are machine-readable for aggregation. If maintainer prefers silent admin merges, the brief still captures the audit-log + label paths which are both invisible to reviewers.

## Acceptance Criteria

- [ ] `--admin` fallback posts PR comment explaining why (with ops markers)
- [ ] Audit log records `merge-admin-fallback` event
- [ ] `admin-merge` label applied to PR
- [ ] Explicit `--admin`/`--auto` callers unaffected (no extra signaling)
- [ ] Regression test covers fallback path
- [ ] ShellCheck clean

## Related

- t2246 / GH#19770 — sibling: CodeRabbit config fix (root cause of PR #19764 bypass)
- `reference/audit-logging.md` — audit log pattern (t1412.8)
- `prompts/build.txt` → "Tamper-Evident Audit Logging"
- GH#18538 — original admin-fallback rationale
- GH#18731 — explicit `--admin`/`--auto` preservation

## Context

Discovered during PR #19764 — admin-fallback fired silently, no PR-level audit trail. Bonus find #6 of 6 from the t2228 retrospective chain.
