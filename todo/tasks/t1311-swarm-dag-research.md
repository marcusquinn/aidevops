# t1311: Swarm DAG Patterns for Supervisor Dispatch — Research Report

**Date:** 2026-02-24
**Source:** `/Users/marcusquinn/Git/oh-my-pi/packages/swarm-extension/`
**Ref:** GH#2135

---

## Executive Summary

oh-my-pi's swarm extension implements a proper DAG-based orchestration engine with YAML-defined agent workflows, topological sort via Kahn's algorithm, and parallel execution waves. Our supervisor dispatch system uses a flat `blocked-by:` string-matching approach in TODO.md with no graph construction, no parallel wave computation, and no `reports_to` concept. This report identifies 6 concrete gaps and proposes 4 enhancements that would bring graph-based dependency resolution to our supervisor without replacing the existing TODO.md-centric architecture.

---

## 1. oh-my-pi Swarm Architecture

### 1.1 Core Components (761 lines total)

| File | Lines | Purpose |
|------|-------|---------|
| `schema.ts` | 148 | YAML parsing, validation, `SwarmAgent`/`SwarmDefinition` types |
| `dag.ts` | 146 | Dependency graph, cycle detection, execution wave computation |
| `executor.ts` | 124 | Spawns individual agents via `runSubprocess` |
| `pipeline.ts` | 216 | Iteration loop, wave-by-wave parallel execution |
| `state.ts` | 127 | Filesystem state persistence (`.swarm_<name>/`) |
| `render.ts` | 75 | TUI progress rendering |

### 1.2 Dependency Model

Two relationship types define the DAG:

```yaml
agents:
  security:
    reports_to: [lead]      # "I produce output for lead"
  lead:
    waits_for: [security]   # "I need security's output"
```

- **`waits_for`**: Explicit forward dependency — "I can't start until X finishes"
- **`reports_to`**: Inverse dependency — "X depends on my output" (equivalent to X having `waits_for: [me]`)

Both are normalized into a single dependency map: `agent_name → Set<dependencies>` (`dag.ts:17-49`).

### 1.3 Dependency Resolution Algorithm

**Kahn's Algorithm** (topological sort) in `dag.ts:63-98`:

1. Compute in-degree for each node (count of unresolved dependencies)
2. Seed queue with all zero-in-degree nodes
3. Process queue: for each node, decrement in-degree of its dependents
4. If sorted count < total nodes → cycle detected (return cycle members)

**Execution Waves** (`dag.ts:106-146`):

1. Start with all nodes as "remaining"
2. Each iteration: collect all nodes whose dependencies are fully in "completed" set
3. That collection = one wave (sorted alphabetically for determinism)
4. Move wave nodes from remaining to completed
5. Repeat until remaining is empty (or deadlock detected)

Result: `string[][]` — array of waves, each wave is an array of agent names that can execute in parallel.

### 1.4 Execution Model

`pipeline.ts` drives execution:

```text
for each iteration (0..targetCount):
  for each wave (0..waves.length):
    Promise.all(wave.map(agent => executeSwarmAgent(agent)))
    // All agents in wave run in parallel
    // Wave N+1 starts only after wave N completes
```

Three modes:
- **`parallel`**: All agents in one wave (unless explicit deps)
- **`sequential`**: Chain by YAML declaration order (implicit deps)
- **`pipeline`**: Repeat the full DAG N times (iterative accumulation)

### 1.5 State Tracking

Persistent filesystem state in `.swarm_<name>/`:
- `state/pipeline.json` — live pipeline + per-agent status
- `logs/orchestrator.log` — wave transitions
- `logs/<agent>.log` — per-agent timestamps
- `context/` — agent session artifacts

Agent states: `pending → waiting → running → completed|failed`

### 1.6 Inter-Agent Communication

Agents communicate through **shared workspace files** — no message passing. The orchestrator manages lifecycle and ordering; agents read/write files in a shared directory.

---

## 2. Our Supervisor Dispatch Architecture

### 2.1 Dependency Model

Single relationship type in TODO.md:

```markdown
- [ ] t002 Implement feature blocked-by:t001,t003
```

- **`blocked-by:`**: Comma-separated task IDs that must complete before this task can start
- **`blocks:`**: Inverse notation (informational, not parsed by dispatch)
- **Indentation**: Parent-child relationship (structural, not dependency)

### 2.2 Dependency Resolution

`auto_unblock_resolved_tasks()` in `todo-sync.sh:1157-1281`:

1. `grep` for all open tasks with `blocked-by:` field
2. For each task, split `blocked-by:` value on commas
3. For each blocker ID, check if it's `[x]` (done) or `[-]` (declined) in TODO.md
4. DB fallback: check if blocker is `complete/deployed/verified/merged` in supervisor DB
5. If ALL blockers resolved → remove `blocked-by:` field from TODO.md line via `sed`

**Key characteristics:**
- String matching (`grep -qE`) — no graph construction
- Linear scan per pulse — O(tasks × blockers)
- No cycle detection
- No wave computation
- Runs in Phase 0.5d of the pulse cycle

### 2.3 Dispatch Model

`cmd_next()` in `state.sh:965-1181`:

1. Query DB for queued tasks ordered by retries ASC, created_at ASC
2. Filter: sibling concurrency limit (max 3 parallel siblings)
3. Cross-repo fair dispatch (round-robin weighted by candidate count)
4. Return up to `$limit` candidates

`cmd_dispatch()` in `dispatch.sh:2530+`:

1. Validate task is queued
2. Pre-dispatch checks (already done, claimed, cross-repo validation)
3. Concurrency check (adaptive, batch-aware)
4. Create worktree, resolve model, build prompt
5. Spawn worker process (nohup + disown)

**Key characteristics:**
- Tasks dispatched one-at-a-time from a flat queue
- No concept of "waves" — tasks are dispatched as slots become available
- Concurrency is global/batch-level, not dependency-aware
- No parallel fan-out/fan-in patterns

### 2.4 State Tracking

SQLite database (`supervisor.db`):
- `tasks` table: id, status, repo, description, model, retries, worktree, branch, log_file, pr_url, etc.
- `state_log` table: full transition history
- `batches` / `batch_tasks`: batch grouping with concurrency limits

Task states: `queued → dispatched → running → evaluating → complete → pr_review → ... → deployed → verified`

---

## 3. Gap Analysis

### Gap 1: No Graph Construction

| Aspect | oh-my-pi | aidevops |
|--------|----------|----------|
| Data structure | `Map<string, Set<string>>` (adjacency list) | String matching via `grep` |
| Construction | Single pass over agent definitions | Per-task grep on each pulse |
| Cycle detection | Kahn's algorithm (O(V+E)) | None |
| Complexity | O(V+E) build + O(V+E) sort | O(T × B × G) where G = grep cost |

**Impact:** Without a graph, we can't detect circular dependencies (`t001 blocked-by:t002`, `t002 blocked-by:t001`). These silently deadlock — both tasks remain blocked forever. The supervisor has no mechanism to detect or report this.

### Gap 2: No Parallel Execution Waves

| Aspect | oh-my-pi | aidevops |
|--------|----------|----------|
| Parallelism | Explicit waves from topological sort | Opportunistic (whatever's unblocked) |
| Determinism | Alphabetical sort within waves | Created-at ordering |
| Fan-out/fan-in | Native (wave 1 → parallel wave 2 → wave 3) | Not supported |

**Impact:** Consider a diamond dependency: `planner → [api, ui, tests] → integrator`. oh-my-pi computes 3 waves and runs api/ui/tests in parallel. Our supervisor would dispatch them one-at-a-time as slots open, with no guarantee they run concurrently. The integrator might start before all three finish if one completes and unblocks it before the others.

Wait — actually, our `blocked-by:` system would handle this correctly IF the integrator has `blocked-by:api,ui,tests`. But there's no mechanism to ensure api/ui/tests are dispatched simultaneously for maximum parallelism.

### Gap 3: No `reports_to` Concept

| Aspect | oh-my-pi | aidevops |
|--------|----------|----------|
| Forward deps | `waits_for` | `blocked-by:` |
| Inverse deps | `reports_to` | `blocks:` (informational only, not parsed) |

**Impact:** `reports_to` is syntactic sugar — it's equivalent to the target having `waits_for`. But it enables a natural authoring pattern: "I report to the lead" vs "the lead waits for me". Our `blocks:` field exists but is never parsed by the dispatch system. Making it functional would be trivial.

### Gap 4: No Execution Mode Abstraction

| Aspect | oh-my-pi | aidevops |
|--------|----------|----------|
| Modes | `pipeline`, `parallel`, `sequential` | Implicit (whatever order tasks are queued) |
| Iteration | `target_count` for pipeline mode | No concept |

**Impact:** oh-my-pi's pipeline mode (repeat the full DAG N times) enables iterative accumulation patterns — e.g., "find 50 sources, one per iteration". Our supervisor has no equivalent. Batches group tasks but don't iterate them.

### Gap 5: No Batch-Level Dependency Ordering

| Aspect | oh-my-pi | aidevops |
|--------|----------|----------|
| Batch ordering | Waves computed from DAG | `batch_tasks.position` (manual ordering) |
| Dependency-aware dispatch | Yes (wave N+1 waits for wave N) | No (all queued tasks compete for slots) |

**Impact:** When a batch has tasks with inter-dependencies, the supervisor dispatches them based on queue position and slot availability, not dependency order. A task might be dispatched before its dependency completes if it happens to be next in the queue and the dependency hasn't been checked yet.

Phase 0.5d (`auto_unblock_resolved_tasks`) runs once per pulse and removes `blocked-by:` fields. But between pulses, a task could be dispatched if its `blocked-by:` was already removed in a previous pulse while the blocker was still running.

### Gap 6: No Shared Workspace Communication

| Aspect | oh-my-pi | aidevops |
|--------|----------|----------|
| Inter-agent comms | Shared workspace filesystem | None (each worker has its own worktree) |
| Signal files | `signals/finder_out.txt` | Not applicable |
| Tracking files | `processed.txt`, `tracking/count.txt` | Not applicable |

**Impact:** Our workers operate in isolated worktrees and communicate only through git (commits, PRs). This is actually a strength for code tasks — isolation prevents conflicts. But it means we can't do oh-my-pi-style data pipelines where agents pass intermediate results through files.

---

## 4. Proposed Enhancements

### Enhancement 1: Graph-Based Dependency Resolution (HIGH PRIORITY)

**What:** Replace the linear `grep`-based blocker checking in `auto_unblock_resolved_tasks()` with a proper dependency graph that's built once per pulse and used for both unblocking and dispatch ordering.

**Implementation:**

Add a new function `build_task_dependency_graph()` to `todo-sync.sh`:

```bash
# Build adjacency list from TODO.md blocked-by: fields
# Output: JSON object { "t002": ["t001", "t003"], "t004": ["t002"] }
build_task_dependency_graph() {
    local todo_file="$1"
    local graph="{}"
    
    while IFS= read -r line; do
        local task_id blocked_by
        task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
        blocked_by=$(printf '%s' "$line" | grep -oE 'blocked-by:[^ ]+' | head -1 | sed 's/blocked-by://')
        [[ -z "$task_id" || -z "$blocked_by" ]] && continue
        
        # Add to graph as JSON
        local deps_json
        deps_json=$(printf '%s' "$blocked_by" | tr ',' '\n' | jq -R . | jq -s .)
        graph=$(printf '%s' "$graph" | jq --arg id "$task_id" --argjson deps "$deps_json" '. + {($id): $deps}')
    done < <(grep -E '^\s*- \[ \] t[0-9]+.*blocked-by:' "$todo_file" || true)
    
    printf '%s' "$graph"
    return 0
}
```

Add cycle detection:

```bash
# Detect cycles using iterative DFS (Kahn's algorithm in shell)
# Returns: comma-separated cycle members, or empty if acyclic
detect_dependency_cycles() {
    local graph_json="$1"
    # ... Kahn's algorithm implementation ...
    # If sorted_count < total_nodes, return unsorted nodes (cycle members)
}
```

**Files to modify:**
- `.agents/scripts/supervisor/todo-sync.sh` — add graph builder + cycle detection
- `.agents/scripts/supervisor/pulse.sh` — call graph builder in Phase 0.5d, log cycles as warnings

**Effort:** ~4h
**Value:** Prevents silent deadlocks, enables wave computation (Enhancement 2)

### Enhancement 2: Execution Wave Computation for Batches (HIGH PRIORITY)

**What:** When a batch is created with inter-dependent tasks, compute execution waves and dispatch wave-by-wave instead of flat queue order.

**Implementation:**

Add `compute_batch_waves()` to `batch.sh`:

```bash
# Compute execution waves from batch task dependencies
# Input: batch_id
# Output: JSON array of arrays [["t001","t002"], ["t003"], ["t004","t005"]]
compute_batch_waves() {
    local batch_id="$1"
    
    # Get all tasks in batch with their blocked-by deps
    local tasks_json
    tasks_json=$(db -json "$SUPERVISOR_DB" "
        SELECT t.id, t.description
        FROM batch_tasks bt
        JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$(sql_escape "$batch_id")'
        ORDER BY bt.position;
    ")
    
    # Build dependency graph from TODO.md blocked-by fields
    # ... use build_task_dependency_graph() ...
    
    # Compute waves via topological sort
    # ... Kahn's algorithm adapted for shell ...
    
    # Store waves in batch metadata
    db "$SUPERVISOR_DB" "UPDATE batches SET waves = '...' WHERE id = '...';"
}
```

Modify `cmd_next()` to respect wave ordering:

```bash
# In cmd_next(), after fetching candidates:
# If batch has computed waves, only return tasks from the current wave
# (i.e., tasks whose wave predecessors are all complete)
```

**Files to modify:**
- `.agents/scripts/supervisor/batch.sh` — add wave computation
- `.agents/scripts/supervisor/state.sh` — modify `cmd_next()` to respect waves
- `.agents/scripts/supervisor/database.sh` — add `waves` column to batches table

**Effort:** ~6h
**Value:** Enables diamond/fan-out/fan-in patterns; maximizes parallelism within dependency constraints

### Enhancement 3: Make `blocks:` Functional (LOW EFFORT, MEDIUM VALUE)

**What:** Parse the existing `blocks:` field in TODO.md as the inverse of `blocked-by:`. When building the dependency graph, treat `blocks:t003` on task t001 as equivalent to `blocked-by:t001` on task t003.

**Implementation:**

In `build_task_dependency_graph()`, add a second pass:

```bash
# Second pass: process blocks: fields (inverse direction)
while IFS= read -r line; do
    local task_id blocks_field
    task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
    blocks_field=$(printf '%s' "$line" | grep -oE 'blocks:[^ ]+' | head -1 | sed 's/blocks://')
    [[ -z "$task_id" || -z "$blocks_field" ]] && continue
    
    # For each blocked task, add this task as a dependency
    IFS=',' read -ra blocked_tasks <<< "$blocks_field"
    for blocked_id in "${blocked_tasks[@]}"; do
        # Add task_id to blocked_id's dependency set
        graph=$(printf '%s' "$graph" | jq --arg id "$blocked_id" --arg dep "$task_id" \
            'if .[$id] then .[$id] += [$dep] else . + {($id): [$dep]} end')
    done
done < <(grep -E '^\s*- \[ \] t[0-9]+.*blocks:' "$todo_file" || true)
```

This is the exact equivalent of oh-my-pi's `reports_to` → `waits_for` normalization (`dag.ts:33-40`).

**Files to modify:**
- `.agents/scripts/supervisor/todo-sync.sh` — extend graph builder

**Effort:** ~1h
**Value:** Enables natural "I produce output for X" authoring pattern

### Enhancement 4: Dependency Visualization in Status Output (LOW EFFORT, HIGH VALUE)

**What:** Add a `supervisor-helper.sh dag` command that renders the task dependency graph as ASCII art or Mermaid diagram, showing waves and current execution state.

**Implementation:**

```bash
cmd_dag() {
    local repo_path="${1:-.}"
    local todo_file="$repo_path/TODO.md"
    
    # Build graph
    local graph_json
    graph_json=$(build_task_dependency_graph "$todo_file")
    
    # Detect cycles
    local cycles
    cycles=$(detect_dependency_cycles "$graph_json")
    if [[ -n "$cycles" ]]; then
        echo "WARNING: Circular dependencies detected: $cycles"
    fi
    
    # Compute waves
    local waves_json
    waves_json=$(compute_waves_from_graph "$graph_json")
    
    # Render as Mermaid
    echo '```mermaid'
    echo 'graph LR'
    # ... render nodes with status colors, edges from deps ...
    echo '```'
}
```

**Files to modify:**
- `.agents/scripts/supervisor-helper.sh` — add `dag` subcommand
- `.agents/scripts/supervisor/todo-sync.sh` — add rendering functions

**Effort:** ~3h
**Value:** Makes dependency relationships visible; helps debug stuck tasks

---

## 5. What NOT to Adopt

### 5.1 YAML Pipeline Definitions

oh-my-pi defines swarms in YAML files with agent roles, tasks, and dependencies. Our system uses TODO.md as the single source of truth. Introducing a parallel YAML definition would create a sync problem. **Keep TODO.md as the authority.**

### 5.2 Shared Workspace Communication

oh-my-pi agents communicate through shared filesystem files. Our workers use isolated git worktrees, which prevents merge conflicts and enables independent PR creation. **Keep worktree isolation.** If inter-task data passing is needed, use git artifacts (committed files in a shared branch) or the supervisor DB.

### 5.3 Pipeline Iteration Mode

oh-my-pi's `target_count` repeats the full DAG N times. This is useful for data collection pipelines but doesn't map to our task model where each task is a unique unit of work. **Don't add iteration mode** — if iterative work is needed, create N tasks with appropriate dependencies.

### 5.4 Full TypeScript Rewrite

oh-my-pi's swarm is 761 lines of TypeScript with proper types, async/await, and `Promise.all`. Our supervisor is 35K lines of bash. A full rewrite is not justified — the proposed enhancements add graph capabilities within the existing shell architecture using `jq` for JSON graph manipulation.

---

## 6. Implementation Priority

| # | Enhancement | Effort | Value | Priority |
|---|------------|--------|-------|----------|
| 1 | Graph-based dependency resolution | ~4h | Prevents deadlocks, enables waves | **P0** |
| 2 | Execution waves for batches | ~6h | Maximizes parallelism | **P1** |
| 3 | Make `blocks:` functional | ~1h | Natural authoring | **P2** |
| 4 | Dependency visualization | ~3h | Debugging, observability | **P2** |
| **Total** | | **~14h** | | |

### Recommended Implementation Order

1. **Enhancement 1** first — it's the foundation for everything else
2. **Enhancement 3** alongside Enhancement 1 (trivial addition to graph builder)
3. **Enhancement 2** after Enhancement 1 is proven (depends on graph builder)
4. **Enhancement 4** last (nice-to-have, depends on graph builder)

---

## 7. Comparison Summary

| Capability | oh-my-pi Swarm | aidevops Supervisor | Gap Severity |
|-----------|---------------|-------------------|-------------|
| Dependency declaration | `waits_for` + `reports_to` | `blocked-by:` (+ unused `blocks:`) | Low |
| Graph construction | `Map<string, Set<string>>` | None (string matching) | **High** |
| Cycle detection | Kahn's algorithm | None | **High** |
| Execution waves | Topological sort → `string[][]` | None (flat queue) | **High** |
| Parallel execution | `Promise.all` per wave | Opportunistic slot-filling | Medium |
| State persistence | Filesystem JSON | SQLite DB | Equivalent |
| Inter-agent comms | Shared workspace files | Git worktree isolation | N/A (different model) |
| Execution modes | pipeline/parallel/sequential | Implicit | Low |
| Progress rendering | TUI widget | CLI status command | Equivalent |
| Model routing | Single model per swarm | Per-task AI-classified tier | aidevops is superior |
| Retry/escalation | None | Prompt-repeat → model escalation | aidevops is superior |
| Quality gates | None | AI-assessed output quality | aidevops is superior |

---

## 8. Key Insight

oh-my-pi's swarm is a **purpose-built orchestration engine** for multi-agent workflows defined upfront in YAML. Our supervisor is a **task management system** that dispatches work from a living TODO.md document. The architectures serve different needs:

- **oh-my-pi**: "Here's a fixed workflow with known agents and dependencies — execute it"
- **aidevops**: "Here's a backlog of tasks that evolve over time — dispatch them efficiently"

The right approach is not to replicate oh-my-pi's architecture, but to **graft its graph-based dependency resolution onto our existing task management model**. Enhancements 1-4 do exactly this: they add a dependency graph layer that's built from TODO.md's `blocked-by:`/`blocks:` fields, used for cycle detection and wave computation, and integrated into the existing dispatch pipeline.

The supervisor's strengths — AI-classified model routing, prompt-repeat retry, quality gates, cross-repo fairness, adaptive concurrency — are capabilities oh-my-pi lacks entirely. The combination of graph-based dependency resolution with AI-driven dispatch decisions would be more powerful than either system alone.

---

## 9. Post-Migration Review (2026-02-25)

**Reviewer:** AI (opus-tier review of prior opus-tier research)
**Context:** The supervisor underwent a major AI-first migration (t1312-t1321, 8 PRs merged) between the original research (2026-02-24) and this review. The codebase grew from 35,741 to 36,526 lines. This section evaluates whether the proposed enhancements remain valid.

### 9.1 What Changed Since the Research

1. **AI-first decision migration completed.** Decision logic in dispatch, pulse, deploy, evaluate, sanity-check, self-heal, routine-scheduler, and issue-sync was migrated from hardcoded heuristics to the gather-decide-execute AI pipeline (`ai-lifecycle.sh`, `ai-reason.sh`). The supervisor now asks an AI model "what should I do?" rather than following case/if-else trees.

2. **`auto_unblock_resolved_tasks()` is unchanged.** The function at `todo-sync.sh:1157-1291` still uses the same grep-based string matching approach documented in Section 2.2. No graph construction, no cycle detection, no wave computation was added.

3. **`blocked-by:` usage is extensive.** TODO.md currently has ~261 lines with `blocked-by:` fields and ~9 with `blocks:`. The dependency system is the primary mechanism for task ordering.

4. **Supervisor line count increased** (35,741 -> 36,526, +785 lines). The AI migration replaced decision logic with AI calls (prompt construction + response parsing) at roughly equal line count, plus new modules were added.

### 9.2 Enhancement Reassessment

#### Enhancement 1: Graph-Based Dependency Resolution — STILL VALID, PRIORITY ELEVATED

The AI-first migration makes this **more** important, not less. The AI lifecycle engine now makes dispatch decisions, but it operates on the same flat task list with no graph context. When `ai-reason.sh` builds a prompt asking "which task should I dispatch next?", it has no visibility into:

- Whether dispatching task X would create a deadlock (circular dependency)
- Which tasks form a parallelizable wave
- Whether a blocked task's entire dependency chain is stalled

Providing the AI with a dependency graph as structured context would improve its dispatch decisions. Instead of the AI inferring dependencies from task descriptions, it would receive `{"waves": [["t001","t002"], ["t003"]], "cycles": [], "critical_path": ["t001","t003","t005"]}` as input.

**Revised approach:** Rather than replacing `auto_unblock_resolved_tasks()` with a shell-based graph builder (as originally proposed), the graph should be built as **AI context** — a structured summary fed to `ai-context.sh` for dispatch decisions. The unblocking logic can remain as-is (it works correctly), but the graph provides the AI with a global view for smarter ordering.

**Revised effort:** ~3h (simpler than original — build graph for context, not for execution control)

#### Enhancement 2: Execution Waves for Batches — DEPRIORITIZED

The AI-first migration partially addresses this. The AI lifecycle engine can now reason about batch ordering: "these 3 tasks have no dependencies on each other, dispatch them in parallel." The AI doesn't need explicit wave computation if it receives the dependency graph (Enhancement 1) as context.

However, the AI can only suggest — the mechanical dispatch still processes tasks one-at-a-time per pulse. True parallel wave execution would require changes to the dispatch loop itself, which is mechanical plumbing.

**Revised priority:** P2 (was P1). The AI can approximate wave behavior with graph context. Explicit wave computation is an optimization, not a correctness fix.

#### Enhancement 3: Make `blocks:` Functional — STILL VALID, TRIVIAL

Only 9 lines in TODO.md use `blocks:` vs 261 using `blocked-by:`. The field is rarely used because it's informational-only. Making it functional in the graph builder (Enhancement 1) is a ~30-minute addition. No change to assessment.

**Revised effort:** ~30min (bundled with Enhancement 1)

#### Enhancement 4: Dependency Visualization — STILL VALID, HIGHER VALUE

With the AI-first migration, the supervisor's decision-making is less transparent (AI reasoning vs deterministic code paths). A `dag` visualization command becomes more valuable for debugging: "why did the AI dispatch task X before task Y?" The graph shows the dependency structure the AI was reasoning about.

**Revised effort:** ~2h (simpler with jq-based graph from Enhancement 1)

### 9.3 Revised Priority Matrix

| # | Enhancement | Effort | Value | Priority | Change |
|---|------------|--------|-------|----------|--------|
| 1 | Graph-based dependency resolution (as AI context) | ~3h | Prevents deadlocks, improves AI dispatch decisions | **P0** | Approach changed: graph as AI context, not execution control |
| 3 | Make `blocks:` functional | ~30min | Natural authoring, bundled with #1 | **P0** | Bundled with #1 |
| 4 | Dependency visualization (`dag` command) | ~2h | Debugging AI decisions, observability | **P1** | Elevated from P2 |
| 2 | Execution waves for batches | ~6h | Maximizes parallelism | **P2** | Deprioritized: AI approximates this |
| **Total** | | **~11.5h** | | | -2.5h from original |

### 9.4 Cycle Detection: Concrete Evidence of Need

The supervisor comments on issue #2135 show a real example of the cycle detection gap: t1311 itself was stuck for days because of a "malformed blocked-by field (backtick character)" — a data quality issue that a graph builder with validation would have caught immediately. The supervisor's AI made 8 separate priority adjustment recommendations about this single task without detecting the root cause (malformed dependency reference).

A graph builder that validates all `blocked-by:` references point to existing task IDs would have flagged this in the first pulse.

### 9.5 Recommendation

**Implement Enhancement 1 + 3 as a single PR (~3.5h).** This provides:

1. A `build_task_dependency_graph()` function that constructs a JSON adjacency list from `blocked-by:` and `blocks:` fields
2. Cycle detection via Kahn's algorithm (adapted for shell/jq)
3. Validation of blocker references (flag non-existent task IDs)
4. Graph summary injected into `ai-context.sh` for dispatch decisions

This is the highest-value, lowest-risk change. It doesn't modify the existing unblocking or dispatch mechanics — it adds a read-only analysis layer that improves AI decision quality and catches data quality issues.

**Defer Enhancements 2 and 4** until Enhancement 1 is proven in production. Enhancement 4 (visualization) is a natural follow-up once the graph builder exists.

### 9.6 Conclusion

The original research is **accurate and well-structured**. The gap analysis (Section 3) and "What NOT to Adopt" recommendations (Section 5) remain fully valid after the AI-first migration. The key insight (Section 8) — graft graph-based resolution onto the existing architecture rather than replacing it — is the correct approach.

The AI-first migration shifts the implementation strategy: instead of the graph driving mechanical dispatch decisions, it should inform AI dispatch decisions as structured context. This is simpler to implement and more powerful, because the AI can weigh graph structure alongside other factors (model cost, worker availability, cross-repo fairness) that a mechanical wave executor cannot.
