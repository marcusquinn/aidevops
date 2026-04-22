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

Age thresholds:
- **Fresh parents** (0 non-nudge comments): ≥`SCANNER_FRESH_PARENT_HOURS` (default 6h)
- **Aged parents** (≥1 non-nudge comments): ≥`SCANNER_NUDGE_AGE_HOURS` (default 24h)

Per-parent state file (`AUTO_DECOMPOSER_PARENT_STATE`) prevents re-filing the same parent within `AUTO_DECOMPOSER_INTERVAL` (default 7 days). The worker's job: read the parent, propose a decomposition plan as children, and stop. Dedup via `source:auto-decomposer` label.

Constants in `pulse-wrapper.sh`: `AUTO_DECOMPOSER_INTERVAL` (7 days), `AUTO_DECOMPOSER_PARENT_STATE`. Maintainer-only (skips `role: contributor` repos).

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

## Use Cases

**Use `#parent` for:** decomposition epics with child implementation tasks, roadmap trackers, research summaries that spawn separate work items, any investigation or "think-before-acting" issue.

**Do NOT use for:** issues that should eventually be implemented as a single unit — those are normal tasks. The point of `#parent` is "this issue will never be implemented directly; only its children will."
