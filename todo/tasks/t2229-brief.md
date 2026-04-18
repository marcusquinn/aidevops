<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2229 Brief — Additive review bot suggestion protocol in build.txt

**Issue:** GH#19750 (marcusquinn/aidevops — filed alongside this brief).

## Session origin

Discovered 2026-04-18 on PR #19712 (t2209). Gemini Code Assist posted a `COMMENTED` review with a valid additive-scope suggestion (extend the duplicate-ID regex to cover declined tasks and routine IDs). The agent had no documented protocol for "additive suggestion on in-review PR" — had to reason whether to expand the PR or file as follow-up. Chose follow-up (now t2222 / #19723), but the decision was case-by-case.

Existing framework covers CodeRabbit `CHANGES_REQUESTED` dismissal (`coderabbit-nits-ok` label) and general review gating (t1382), but not additive-scope review feedback.

## What / Why / How

See issue body for:

- Exact rule text to add near `prompts/build.txt` §"Review Bot Gate" or `reference/review-bot-gate.md`
- Decision tree: correctness issue in current PR's own code → expand PR; additive scope (new feature, expanded coverage, nice-to-have) → file follow-up
- Rationale: one-fix-per-PR audit trail, reduced review cycles, preserves existing approvals

## Acceptance criteria

Listed in issue body. Core assertions:

1. `prompts/build.txt` §Review Bot Gate carries the additive-suggestion decision rule.
2. `reference/review-bot-gate.md` has the expanded rationale.
3. Cross-reference from the new rule to the CodeRabbit dismissal rule (they share context).

## Tier

`tier:simple` — doc-only edit, verbatim text provided in issue body.
