<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2246: .coderabbit.yaml — restore include-all semantics; fix auto-review skip on negative-only filters

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19770
**Tier:** simple (auto-dispatch)

## What

`.coderabbit.yaml` configures only a negative label filter (`"!no-review"` at `:56`) with an inline comment explicitly stating "review everything unless tagged `no-review`". CodeRabbit Pro's actual behaviour contradicts this: on PR #19764 (2026-04-18) the bot skipped auto-review with:

> Review skipped — only excluded labels are configured. (1) * no-review

CodeRabbit treats negative-only label filters as "include nothing" rather than "include all".

## Why

Every maintainer-authored docs-only or planning PR silently skips CodeRabbit review. This degrades the review-bot-gate below its design intent:

1. `origin:interactive` + maintainer-author auto-approves the framework's Maintainer Gate.
2. CodeRabbit was the `reviewDecision: APPROVED` source on PR #19758.
3. On PR #19764, CodeRabbit skipped → `reviewDecision: REVIEW_REQUIRED` → branch protection blocked → `full-loop-helper.sh` `--admin` fallback bypassed the gate entirely.

The config comment at `:47-54` cites GH#17904 which "removed 'external-contributor' positive label that was inadvertently disabling internal PR reviews". That fix addressed positive labels disabling reviews; the current state is *only-negative labels* disabling reviews — regression of the same class. Likely cause: CodeRabbit schema semantics changed since the comment was written.

## How

### Files to modify

- **EDIT:** `.coderabbit.yaml:55-56` (labels section)

### Options (pick ONE — maintainer call)

**Option A (minimal, recommended):** wildcard positive include to restore "review all unless opted out":

```yaml
labels:
  - "*"           # include all PRs
  - "!no-review"  # except those opted-out
```

**Option B (explicit):** enumerate the origin labels the framework uses:

```yaml
labels:
  - "origin:interactive"
  - "origin:worker"
  - "!no-review"
```

Risk under B: external-contributor PRs that haven't yet been labelled with an `origin:*` would be skipped — regression of GH#17904 scenario.

**Option C (permissive):** remove the label filter entirely; rely on `path_filters` (already at `:72`) for scope. Re-introduces GH#3827 rate-limit pressure.

### Recommendation

Option A. Preserves the original intent exactly; explicit include wildcard defeats the negative-only edge case; no risk of GH#17904 regression.

### Cross-check before committing

- Read CodeRabbit schema at `https://coderabbit.ai/integrations/schema.v2.json` (referenced in yaml header at `:1`) to confirm `"*"` is a valid include pattern. If not, fall to Option B with a loud comment about the GH#17904 tradeoff.

### Verification

- Push a test PR with `origin:interactive` label → CodeRabbit posts a review (not "skipped").
- Push a test PR with `no-review` label → CodeRabbit skips (opt-out preserved).
- Check external-contributor scenario: a PR with no `origin:*` and no `no-review` → under Option A, reviewed; under Option B, skipped (GH#17904 regression signal).

### Files to modify

- EDIT: `.coderabbit.yaml:55-56`
- Optionally update the comment at `:47-54` to describe the new "positive include + negative exclude" intent.

## Acceptance Criteria

- [ ] Internal PRs (maintainer or worker) with `origin:*` labels get auto-reviewed (not skipped)
- [ ] `no-review` label still opts out
- [ ] External-contributor PRs not accidentally locked out
- [ ] PR body links to a test PR that triggered a real CodeRabbit review (as proof)
- [ ] Comment at `:47-54` updated to match new semantics

## Context

Discovered during PR #19764 — CodeRabbit silently skipped, forced `--admin` fallback in `full-loop-helper.sh::_merge_execute`. Bonus find #5 of 6 from the t2228 retrospective chain.
