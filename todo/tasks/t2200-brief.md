<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2200 Brief — Enforce origin:interactive and origin:worker label mutual exclusion

**Issue:** GH#19688 (marcusquinn/aidevops) — issue body is the canonical spec.

## Session origin

Filed 2026-04-18 from the t2189 interactive session (PR #19682). During triage of the first dogfood target for PR #19682 (issue #19658 / #19638), I noticed issue #19638 has BOTH `origin:interactive` AND `origin:worker` labels simultaneously. These are supposed to be mutually exclusive by construction — a given issue was created by EITHER an interactive session OR a headless worker, never both. The framework's dispatch-dedup, review gates, and operator mental model all assume exclusivity; violations create brittle behaviour dependent on label-read order.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19688 for:
- Root cause: no framework-level invariant enforcement on origin labels
- Fix: `_set_origin_label` helper in `shared-constants.sh` that atomically applies one origin label + removes the other two (origin:interactive, origin:worker, origin:worker-takeover)
- All write sites in claim-task-id.sh, issue-sync-helper.sh, pulse-wrapper.sh, full-loop-helper.sh refactored to call the helper
- One-off reconciliation pass to clean up existing dual-label issues like #19638
- Regression test exercising both ordering cases

## Acceptance criteria

Listed in issue body. Key gates: `rg --add-label origin:` returns only the helper itself; #19638 verified clean post-reconciliation; regression test passes.

## Tier

`tier:standard` — touches 4+ scripts + adds helper + reconciliation script + test. Not trivial but no novel design needed.

## Relation

- t2199 (wrapper discoverability): those wrappers should use `_set_origin_label` internally. Sequence: land t2200 first so t2199's wrappers can call the helper from day one.
