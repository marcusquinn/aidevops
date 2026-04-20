<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2442: auto-decomposer + parent-task gate hardening — eliminate backlog black hole from undecomposed parents

## Pre-flight

- [x] Memory recall: `pulse-issue-reconcile parent children` → 2 hits — t2244 tightened `_extract_children_section` to heading-scoped; t2138 added GraphQL sub-issue fallback. Both MUST be preserved (not regressed).
- [x] Memory recall: `PARENT_TASK_BLOCKED dispatch` → 3 hits — t2211 `parent-task` is only reliable block vs maintainer auto-approve; t2053.1/t2099 taught catastrophic cost of loose #NNN matching in parent-close path.
- [x] Discovery pass: 0 open PRs on target files last 48h. Recent merged PRs relevant: PR #20117 (t2436 synchronous parent-task label at creation), PR #19928 (t2388 nudge), PR #19810 (t2244 heading-scoped extraction), PR #19981 (t2350 umbrella-style parent-task backfill).
- [x] File refs verified: all target file:line refs below confirmed at HEAD `f1064bac5342302c91060fb6c2d76b4723bd5012` (chore: claim t2442).
- [x] Tier: `tier:standard` — 6 files + 4 new test files + 1 new scanner + new command doc. Multi-file, cross-concern (reconcile + sync + scanner + AGENTS.md). Judgment required in prose pattern design (narrow is critical — t2244 lesson). Not `tier:thinking` (no novel architecture; extends 3 well-established patterns).

## Origin

- **Created:** 2026-04-20
- **Session:** Claude Code:interactive
- **Created by:** ai-interactive (root-cause analysis by user-led session)
- **Parent task:** none (root systemic fix)
- **Conversation context:** User asked "What are all the things in our current open issues with waiting for something?" Analysis surfaced 8 stuck issues in aidevops backlog — all but one (#20128 running) were `parent-task` labeled with nudge comments from 2026-04-19 that nobody acted on. Root cause: t2388 decomposition-nudge is advisory-only with no automation path. Without converting nudges into active work, parent-task effectively becomes a permanent dispatch black hole.

## What

Eliminate the "parent-task dispatch black hole" via four systemic fixes in one PR:

1. **Auto-decomposer scanner (Fix #1).** Daily scan of parent-task issues with a nudge comment ≥24h old and still zero filed children. Files a fresh issue (`<!-- aidevops:generator=auto-decompose parent=NNNN -->` marker, `tier:thinking` label, worker-ready brief requesting that the worker (a) read the parent body, (b) file 2-N child issues with full briefs and phase labels, (c) edit the parent body to add a canonical `## Children` section linking them, (d) close the auto-decompose issue with a summary). Idempotent — skips if prior auto-decompose issue is still open or closed within 72h.

2. **Parent-task application warn gate (Fix #2).** When `#parent`/`#meta`/`#parent-task` tag is mapped to the `parent-task` label via `map_tags_to_labels`, also stamp a diagnostic into a warn file if the body is opaque about decomposition (no `## Phase`, `## Children`, `## Sub-tasks`, `## Child issues` heading AND no `Phase 1`, `Blocked by:`, `tracks #NNNN`, `filed as #NNNN` prose). Non-blocking — maintainer can suppress by adding those markers. Surfaces via a one-time comment on the issue created with `parent-task` when the warn fires, marker `<!-- parent-task-no-phase-markers -->`.

3. **Widen child detection with narrow prose patterns (Fix #3).** Add NEW helper `_extract_children_from_prose` in `pulse-issue-reconcile.sh` (separate from existing t2244 `_extract_children_section` — not a replacement). Matches narrow patterns only:
    - `Phase [0-9]+ .* #([0-9]+)` (e.g. "Phase 1 split out as #19996")
    - `filed as #([0-9]+)`
    - `tracks #([0-9]+)`
    - `Blocked by: #([0-9]+)` / `blocked-by: #([0-9]+)`
    - `^[-*][ ] .*#([0-9]+)` only within `## Phases` / `## Child issues` / `## Children` heading (already covered by t2244 — keep identical behaviour)

    Wired in `reconcile_completed_parent_tasks` AFTER the existing graph + heading-scoped extraction, as a third fallback. Never mutates the parent body.

4. **Decomposition escalation (Fix #4).** When a parent-task has had a nudge comment for ≥7 days AND still zero filed children AND the auto-decomposer ran without converting it to children (idempotent skip on open auto-decompose issue), post a one-time escalation comment (marker `<!-- parent-needs-decomposition-escalated -->`), apply `needs-maintainer-review`, and add the escalation to the pulse health counters. The escalation body MUST include the path-forward: "maintainer decides decompose / drop parent-task / close / file explicit children".

## Why

- **Observable impact.** In the current backlog (verified 2026-04-20), 743+ `PARENT_TASK_BLOCKED` events in `~/.aidevops/logs/pulse.log`. All stuck issues except #20128 have `parent-task` label and an unactioned nudge comment. The supervisor loops fruitlessly because there is no forward path.
- **Framework cost.** Every pulse cycle wastes API calls iterating the blocked parent-tasks and re-checking them; every worker-capable window is wasted on idle time.
- **Architectural flaw.** t2388 correctly identified the "silent stuck" state and posts a nudge. But the nudge terminates at the maintainer's inbox. There was no automation to convert that prompt into work — it was "mentor the human" only. The framework's own rule (`prompts/build.txt` Reasoning responsibility) says the AI should recommend not ask; t2442 closes the loop by dispatching a thinking-tier worker to do the decomposition itself.
- **Failure mode already proven.** #19858 and #19859 were mis-labeled `parent-task` — both were single-unit tasks. They sat with nudges for >24h because no code path recognised they were mislabel vs truly needing decomposition. Fix #2 flags this class at creation time (body-shape warning); Fix #1 dispatches for true parents.
- **Why all four in one PR.** They form a cohesive gate stack (creation warn → nudge at 24h → auto-decompose at 24h → escalate at 7d). Landing them separately would mean each depends on the others for value. The PR stays cohesive: one feature area, one test suite.

## How

### Files to modify

- **EDIT: `.agents/scripts/pulse-issue-reconcile.sh`** — three edits inside this single file:
  1. Add `_extract_children_from_prose` helper (new function, insert after `_extract_children_section` at line 1010). Model on `_extract_children_section`'s awk/grep style.
  2. Add `_post_parent_decomposition_escalation` helper (new function, insert after `_post_parent_decomposition_nudge` at line 1090). Model on `_post_parent_decomposition_nudge` — same idempotency-marker pattern, different marker (`<!-- parent-needs-decomposition-escalated -->`), additionally applies `needs-maintainer-review` label.
  3. In `reconcile_completed_parent_tasks` (line 1141), insert Fix #3 fallback call AFTER existing heading-scoped extraction (around line 1186). Insert Fix #4 escalation call AFTER the existing nudge call (line 1195-1201) inside the `if [[ -z "$child_nums" ]]` block.

- **EDIT: `.agents/scripts/issue-sync-lib.sh`** — Fix #2 extended `map_tags_to_labels` at line 643. Keep existing aliasing behaviour (`parent` → `parent-task`). Add a SIDE effect (warn to stderr if logs enabled) but do NOT modify the returned labels. Keep label resolution pure.

- **EDIT: `.agents/scripts/issue-sync-helper.sh`** at line 759 — after `labels=$(map_tags_to_labels "$tags")`, if `parent-task` is in the result, call new helper `_check_parent_body_has_phase_markers` against the TODO entry body or upcoming issue body; queue a post-creation comment to warn if no markers found.

- **EDIT: `.agents/scripts/claim-task-id.sh`** at line 1747-1758 — when `_todo_derived_labels` contains `parent-task`, same warn protocol: queue the no-phase-markers comment for post-creation.

- **EDIT: `.agents/scripts/pulse-dispatch-engine.sh`** at line 1193 — register `_run_auto_decomposer_scanner` via `run_stage_with_timeout` right after `reconcile_parent_tasks`. Respect the same 24h `AUTO_DECOMPOSER_INTERVAL` gating pattern as `_run_post_merge_review_scanner` at line 1155.

- **EDIT: `.agents/AGENTS.md`** — extend "Parent / meta tasks (`#parent` tag, t1986)" section documenting the 4 new behaviours. Keep the existing synopsis and append a "Decomposition lifecycle (t2442)" sub-section.

### Files to CREATE

- **NEW: `.agents/scripts/auto-decomposer-scanner.sh`** — standalone scanner script. Model on `post-merge-review-scanner.sh` structure (header comments, `SCANNER_DAYS`/`SCANNER_MAX_ISSUES` env vars, `log()` helper, `get_lookback_date` for nudge-age filtering, main scan loop).
  Responsibilities:
  - Iterate pulse-enabled maintainer-role repos.
  - Per repo: list open `parent-task` issues.
  - For each, read comments: if `<!-- parent-needs-decomposition -->` marker is present AND its comment age ≥24h AND no `<!-- aidevops:generator=auto-decompose parent=<N> -->` child issue is still open (search via `gh search issues`), file a new worker-ready issue.
  - Cap: 3 new decomposer issues per repo per scan cycle.
  - Subcommands: `scan|dry-run|help`.

- **NEW: `.agents/scripts/commands/auto-decompose.md`** — command doc for the dispatched worker. Defines the three-outcome protocol (premise-falsified-close / decompose-and-file-children / escalate-with-recommendation) mirroring review-followup.

- **NEW: `.agents/scripts/tests/test-parent-prose-child-detection.sh`** — fixture-based tests for `_extract_children_from_prose`. Mirror `test-reconcile-parent-body-parse.sh` structure. Cases:
  - `Phase 1 split out as #19996` → extracts `19996`.
  - Prose `Triggered by #19708` (context not child) → does NOT extract.
  - `## Children` section with `- #12345` → returns empty (that's what `_extract_children_section` is for; this helper ignores headings).
  - `filed as #12` + `tracks #13` → extracts both.
  - Guard: must not collapse with heading-scoped path.

- **NEW: `.agents/scripts/tests/test-parent-task-application-warn.sh`** — fixture tests for the Fix #2 body-shape check:
  - Body with `## Phase 1` → no warn.
  - Body with `Blocked by: #42` → no warn.
  - Body with only prose, no markers → warn triggered.
  - Body with `## Children` → no warn.

- **NEW: `.agents/scripts/tests/test-parent-decomposition-escalation.sh`** — structural test mirroring `test-pulse-parent-nudge.sh`:
  - Helper `_post_parent_decomposition_escalation` defined.
  - Uses canonical marker `<!-- parent-needs-decomposition-escalated -->`.
  - Applies `needs-maintainer-review` label.
  - Idempotent via marker lookup.
  - Triggered only when nudge age ≥7d.

- **NEW: `.agents/scripts/tests/test-auto-decomposer-scanner.sh`** — smoke test:
  - Scanner script is executable.
  - Scanner respects `--dry-run`.
  - Scanner's issue body contains required sections (Worker Guidance, file:line, generator marker).

### Verification

```bash
# Inside the worktree
cd /Users/marcusquinn/Git/aidevops-feature-t2442-auto-decomposer-parent-task-gate

# Shellcheck all modified scripts
shellcheck .agents/scripts/pulse-issue-reconcile.sh \
    .agents/scripts/issue-sync-lib.sh \
    .agents/scripts/issue-sync-helper.sh \
    .agents/scripts/claim-task-id.sh \
    .agents/scripts/pulse-dispatch-engine.sh \
    .agents/scripts/auto-decomposer-scanner.sh

# Run new tests
bash .agents/scripts/tests/test-parent-prose-child-detection.sh
bash .agents/scripts/tests/test-parent-task-application-warn.sh
bash .agents/scripts/tests/test-parent-decomposition-escalation.sh
bash .agents/scripts/tests/test-auto-decomposer-scanner.sh

# Run existing regression tests to prove no breakage
bash .agents/scripts/tests/test-reconcile-parent-body-parse.sh
bash .agents/scripts/tests/test-pulse-parent-nudge.sh
bash .agents/scripts/tests/test-parent-task-guard.sh
bash .agents/scripts/tests/test-parent-tag-sync.sh
bash .agents/scripts/tests/test-pulse-reconcile-parent-task-subissue-graph.sh

# Dry-run the scanner against the live aidevops repo
./.agents/scripts/auto-decomposer-scanner.sh dry-run marcusquinn/aidevops
```

## Acceptance

- [ ] `_extract_children_from_prose` added; returns narrow matches only; existing `_extract_children_section` untouched (t2244 preserved).
- [ ] `_post_parent_decomposition_escalation` added; idempotent marker; applies `needs-maintainer-review`.
- [ ] `reconcile_completed_parent_tasks` wires both: prose fallback after heading-scoped; escalation call inside the zero-children branch gated on nudge-age ≥7d.
- [ ] `map_tags_to_labels` unchanged in return value; Fix #2 body-shape check implemented in `issue-sync-helper.sh` + `claim-task-id.sh` call sites.
- [ ] `auto-decomposer-scanner.sh` executable; dry-run works against live repo; idempotent via prior-issue-search.
- [ ] `pulse-dispatch-engine.sh` registers `_run_auto_decomposer_scanner` in `_pulse_run_reconcile_pass`.
- [ ] New tests pass; all existing parent-task-related tests still pass.
- [ ] `.agents/AGENTS.md` documents the new lifecycle (creation-warn → nudge-24h → auto-decompose-24h → escalate-7d).
- [ ] `shellcheck` clean on all modified + new scripts.
- [ ] PR carries `Resolves #20139` (this is a leaf issue — NOT a parent-task — so `Resolves` is correct per t2046).

## Context

- **Live backlog snapshot (2026-04-20 pre-fix):** 8 stuck issues; 6 `parent-task` + 1 `status:in-review` (correct) + 1 running. Mis-labels #19858, #19859 already corrected at session start. Genuine parents awaiting decomposition: #20001 (3 explicit phases in body), #19808, #19969 (now has `## Children` section pointing at CLOSED #19996 + placeholders for phases 2-4).
- **Session origin for #20139:** claim-task-id.sh ran in interactive session with `COMPLEXITY_GUARD_DISABLE=1 PRIVACY_GUARD_DISABLE=1` to work around a pre-push hook hang on complexity regression scan (GH#20045-class; tracked separately — not part of this PR).
- **Deployed-vs-source gotcha.** Fixes land in `~/Git/aidevops/.agents/scripts/`. Pulse reads from `~/.aidevops/agents/scripts/`. Deploy requires `setup.sh --non-interactive`. Merge + release hooks handle this automatically per framework convention (see AGENTS.md "Pulse restart after deploying pulse script fixes").

