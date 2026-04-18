<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2225 Brief — Document hook self-block bootstrap playbook

**Issue:** GH#19746 (marcusquinn/aidevops — filed alongside this brief).

## Session origin

Discovered 2026-04-18 during PR #19712 (t2209) shipping session. The pre-commit hook's `validate_duplicate_task_ids` validator was itself buggy and rejected every commit touching TODO.md — including the commit that fixed it. Required explicit `--no-verify` authorization from user. No documented playbook existed for this class of incident; the agent had to reason from first principles and ask permission. Three downstream sibling bugs (t2215/2216/2217) hit the same pattern in the same session.

## What / Why / How

See issue body for:

- Exact file additions (`reference/pre-commit-hooks.md`) + `prompts/build.txt` rule text
- The bootstrap protocol: (1) verify validator is the bug; (2) explicit `--no-verify` authorization; (3) regression test in same PR; (4) authorization does not extend to subsequent commits
- Cross-references to t2036 (stale-deployed-symptom rule) as the runtime-investigation analogue

## Acceptance criteria

Listed in issue body. Core assertions:

1. `prompts/build.txt` carries a "Hook self-block bootstrap" rule in the Git Workflow section.
2. `reference/pre-commit-hooks.md` exists with the full playbook (repro, protocol, regression-test requirement, authorization scope).
3. Existing hook-related references in `build.txt` point to the new doc.

## Tier

`tier:simple` — doc-only edit, verbatim text provided in issue body, no code paths touched.
