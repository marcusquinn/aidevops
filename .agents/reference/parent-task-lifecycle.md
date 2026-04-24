# Parent-Task Decomposition Lifecycle (t2442)

A `parent-task` label is a *permanent dispatch block* — it must be paired with a concrete decomposition plan, or it becomes backlog rot.

**Key rule:** `#parent` is the only reliable dispatch block for maintainer-authored issues. Once a maintainer files with `#parent`, `auto_approve_maintainer_issues()` cannot override it via NMR clearance — `parent-task` short-circuits `dispatch-dedup-helper.sh is-assigned` with `PARENT_TASK_BLOCKED` upstream of the approval path. (t2211)

## Five Cooperating Enforcement Mechanisms

### 1. No-Markers Warning at Label-Application Time (Fix #2)

When `parent-task` is applied to an issue whose body contains none of the recognised decomposition headings — `## Children`, `## Child Issues`, `## Sub-tasks`, `## Phases`, or `## Phase N[: ...]` — `_post_parent_task_no_markers_warning` (in `issue-sync-lib.sh`) posts a one-time comment pointing the author at the four remediation paths.

Called from both `issue-sync-helper.sh cmd_push` and `claim-task-id.sh create_github_issue`. Dedup via `<!-- parent-task-no-markers-warning -->` marker.

### 2. Prose-Pattern Children Extraction (Fix #3)

`_extract_children_from_prose` in `pulse-issue-reconcile.sh` is the third fallback (after graph-based and heading-scoped extraction) for recognising decomposition in issue bodies that don't use formal headings.

Narrow patterns only: `Phase N ... #NNNN`, `filed as #NNNN`, `tracks #NNNN`, `Blocked by: #NNNN`. Widening this set is forbidden — CodeRabbit disqualified "any `#NNN` = child" matching in PR #19810 (t2244).

### 3. 24-Hour Advisory Nudge (t2388)

`reconcile_completed_parent_tasks` posts `_post_parent_task_decomposition_nudge` on parent-tasks with 0 children where ≥24h have elapsed since label application. Dedup via `<!-- parent-task-decomposition-nudge -->` marker.

### 4. Auto-Decomposer Scanner (Fix #1, tightened t2573)

`auto-decomposer-scanner.sh` runs on every pulse cycle via `_run_auto_decomposer_scanner` (in `pulse-simplification.sh`) — the former global 24h run gate was removed in t2573 to allow multiple parents to be cleared per day.

For each open parent-task with 0 children and an eligible nudge, it files a fresh `tier:thinking` worker issue with generator marker `<!-- aidevops:generator=auto-decompose -->`.

Age thresholds (AI-throughput defaults — GH#20532):
- **Fresh parents** (0 non-nudge comments): ≥`SCANNER_FRESH_PARENT_HOURS` (default 0h — fires immediately once nudge exists)
- **Aged parents** (≥1 non-nudge comments): ≥`SCANNER_NUDGE_AGE_HOURS` (default 0h — fires immediately once nudge exists)

The comparison is `age_hours >= threshold_hours` (`-lt` guard), so threshold=0 fires for any nudge age including same-cycle (0h). Override via env var to restore a delay.

Per-parent state file (`AUTO_DECOMPOSER_PARENT_STATE`) prevents re-filing the same parent within `AUTO_DECOMPOSER_INTERVAL` (default 1 day / 86400s). The worker's job: read the parent, propose a decomposition plan as children, and stop. Dedup via `source:auto-decomposer` label.

Constants in `pulse-wrapper.sh`: `AUTO_DECOMPOSER_INTERVAL`, `AUTO_DECOMPOSER_PARENT_STATE`. Maintainer-only (skips `role: contributor` repos).

### 5. 7-Day NMR Escalation (Fix #4)

If the advisory nudge is ≥7 days old and still zero children exist, `_post_parent_decomposition_escalation` applies `needs-maintainer-review` and posts a comment listing the four paths forward:

1. Decompose into children
2. Drop the `parent-task` label
3. Close the issue
4. Let the auto-decomposer handle it

**Escalation never removes `parent-task`** — that would defeat the only reliable dispatch block (per t2211). The label removal instruction appears only as user-facing guidance inside a markdown code fence.

Env override: `PARENT_DECOMPOSITION_ESCALATION_HOURS` (default 168). Capped at `max_escalations` per reconcile pass. Dedup via `<!-- parent-needs-decomposition-escalated -->` marker.

## Test Coverage

`.agents/scripts/tests/test-parent-prose-child-detection.sh`, `test-parent-task-application-warn.sh`, `test-parent-decomposition-escalation.sh`, `test-auto-decomposer-scanner.sh`, `test-auto-decomposer-per-parent-gate.sh` (84+ structural assertions total).

## Sequential Phase Auto-File (t2740, enabled by default since t2787)

The sequential phase auto-file mechanism reads phase declarations from the parent-task issue body and files the **next unfiled phase** as a child issue automatically once the prior phase's PR merges.

**Feature flag:** `AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE` — defaults to `1` (ON) since t2787. Set to `0` to disable.

### Canonical Phase Formats

Two formats are supported. Both are parsed by `_extract_sequential_phases` in `shared-phase-filing.sh`.

**List format (preferred — auto-fire enabled by default):**

```
- Phase 1 - description [auto-fire:on-prior-merge]
- Phase 2 - description [auto-fire:on-prior-merge]
- Phase 3 - description
```

**Narrative bold-heading format (for prose-style decomposition plans):**

```
**Phase 1 — description [auto-fire:on-prior-merge]**
Detailed implementation notes for Phase 1...

**Phase 2 — description**
Detailed implementation notes for Phase 2...
```

### Auto-Fire Markers

| Marker | Behaviour |
|--------|-----------|
| `[auto-fire:on-prior-merge]` | File this phase when the prior phase PR merges (recommended) |
| `[auto-fire:on]` | File immediately — no wait for prior merge |
| *(no marker — list format)* | Filed in sequence (same as `on-prior-merge`) |
| *(no marker — narrative format)* | NOT auto-filed unless `<!-- phase-auto-fire:on -->` appears in the issue body |

The `<!-- phase-auto-fire:on -->` HTML comment is the opt-in for narrative phases without per-phase markers. It applies the `on-prior-merge` behaviour to every unmarked narrative phase in the issue.

### Close Guard

The close guard (t2755 Phase 2) prevents premature parent-task closure while any declared phase is still unfiled or open. If a PR uses a closing keyword (`Closes #NNN`) on a parent-task issue that still has pending phases, the merge is accepted but the issue is re-opened with an explanatory comment.

## Use Cases

**Use `#parent` for:** decomposition epics with child implementation tasks, roadmap trackers, research summaries that spawn separate work items, any investigation or "think-before-acting" issue.

**Do NOT use for:** issues that should eventually be implemented as a single unit — those are normal tasks. The point of `#parent` is "this issue will never be implemented directly; only its children will."
