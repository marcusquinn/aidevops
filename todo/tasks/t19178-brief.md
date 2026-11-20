<!-- aidevops:brief-schema=v2 -->

# t19178: Persistent dispatch exclusions reach the AI brief owner instead of a user session

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `dispatch exclusion stale consolidated label never dispatched supervisor intake` → 0 hits — no relevant lessons
- [x] Discovery pass: 13 commits in the last 48h touch the target files (none add per-issue exclusion ageing); 0 open PRs touch them. The sibling root-cause fix #39315 (t19174) only edits `pulse-dispatch-large-file-gate.sh`, which is outside this scope.
- [x] File refs verified: 9 refs checked against `main` at `53371dd4b7`; all present
- [x] Tier: `tier:thinking` — dispatch-path files (self-hosting) plus an escalation-policy decision
- [x] Seeded draft PR decision recorded: skipped — design choices stay with the worker

## Origin

- **Created:** 2026-11-19
- **Session:** opencode:aidevops-1yu7cb (Pulse/worker throughput mission)
- **Created by:** ai-interactive
- **Conversation context:** The user directive is that "blocked is a label, not an instruction": every stall needs a recorded reason and AI revisiting, without the user opening an interactive session. On 2026-11-19 the user opened three "why is #N unsolved" sessions. Two of them (#28476, #36027) were issues that a deterministic dispatch filter had skipped every cycle for about 37 hours, with nothing escalating them.

## What

When a deterministic dispatch filter skips an `auto-dispatch` issue on every pulse cycle for longer than a threshold (default 24h), Pulse queues that issue once into the existing terminal-blocker recovery intake as `intake: persistent_exclusion`. The entry names the filter. The pulse supervisor, already the AI brief owner for that queue, then either repairs the mechanical cause within existing authority or records exactly one decision that names the human input required. Maintainer, approval and permission gates are never bypassed.

## Why

Evidence from 2026-11-19 (`~/.aidevops/logs/pulse.log`):

- Every cycle logged `Dispatch enumeration: marcusquinn/aidevops consolidated management-label gate skipped #36027 #28476 (blocked:consolidated would always reject; GH#35038)`. Both issues were `auto-dispatch` + `status:available` `file-size-debt` issues reopened by the large-file gate while still carrying a stale `consolidated` label. Stage 0c (`pulse-issue-reconcile-actions.sh:640-672`) deliberately never mutates an issue reopened after its supersession comment, so no component owned the repair.
- #38982 (a canonical consolidated spec, `auto-dispatch`) was held behind #28476 by the large-file gate on `.agents/scripts/headless-runtime-worker.sh` (2025 lines). The deadlock cost about 37 hours, and the user opened `aidevops-28476` and `aidevops-36027` sessions to find it.
- Same day: 49 worker PRs and 71 interactive PRs merged, both with a 0.4h median open time. Workers are fast once dispatched; the throughput loss is in the issues that silently never dispatch.

The specific label defect is fixed by #39315 (t19174). This task closes the class: any future filter-level deadlock reaches the AI owner within about a day instead of waiting for a human.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The edits touch dispatch-path files listed in `.agents/configs/self-hosting-files.conf`. The worker also has to decide which exclusion reasons escalate and how entries retire, without creating noise for real maintainer gates.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/dispatch-exclusion-age-helper.sh` — runner-local per-issue exclusion ageing. Model on the stamp-file pattern in `_dispatch_consolidated_attention_stamp_path` / `_dispatch_consolidated_attention_fresh` (`pulse-dispatch-lib-candidates.sh:1526-1545`).
- `EDIT: .agents/scripts/pulse-dispatch-lib-candidates.sh:1668-1672` — in `_dispatch_filter_consolidated_candidates`, note each skipped issue with reason `consolidated`.
- `EDIT: .agents/scripts/pulse-dispatch-lib.sh:1724-1738` — in `_dispatch_max_prefilter_cached_block`, note `cross_cycle_<reason>` (sanitized to `[a-z_]+`). Skip maintainer-gate reasons other than `consolidated` (`_dispatch_maintainer_gate_reason`, `pulse-dispatch-lib.sh:286-292`); those already surface through `/decisions`.
- `EDIT: .agents/scripts/terminal-blocker-recovery-helper.sh:315-318` — accept `persistent_exclusion` in the `tbr_enqueue` intake case.
- `EDIT: .agents/scripts/terminal-blocker-recovery-helper.sh:1506-1508` — keep `persistent_exclusion` out of the mechanical `rearm` pass, as with `unclassified_hold`.
- `EDIT: .agents/scripts/terminal-blocker-recovery-helper.sh:1521-1528` — route `persistent_exclusion` to a new checker in `terminal-blocker-recovery-holds.sh`.
- `EDIT: .agents/scripts/terminal-blocker-recovery-holds.sh` — add `_tbr_check_exclusion_entry`, modeled on `_tbr_check_unclassified_entry` (`terminal-blocker-recovery-helper.sh:1420-1442`). Put it here so the 2024-line helper does not grow.
- `EDIT: .agents/scripts/pulse-wrapper-cycle.sh:513` — add one sentence for the `persistent_exclusion` intake to the terminal-blocker supervisor prompt.
- `EDIT: .agents/reference/worker-integration-recovery.md:121` — add a short "Persistent dispatch exclusions" paragraph under "Terminal-blocker recovery".

### Complete Write Surface

- **Callers/readers:** `pending` / `pending --count` in `terminal-blocker-recovery-helper.sh`, consumed by `_pulse_blocker_recovery_due` (`pulse-dispatch-engine-supervisor.sh:173-226`), which triggers the supervisor; supervisor prompt `pulse-wrapper-cycle.sh:513`. `record` decisions use the existing `_tbr_decision_active`.
- **Writers/mutation paths:** the new helper writes only `~/.aidevops/logs/dispatch-exclusion-age/<owner>--<repo>--<issue>` and calls `terminal-blocker-recovery-helper.sh enqueue ... persistent_exclusion` once per (issue, reason) streak. No GitHub writes in the helper; the supervisor writes through existing guarded helpers only.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-dispatch-core-consolidated-label.sh`, `.agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh` (cross-cycle block lines), `.agents/scripts/tests/test-terminal-blocker-circuit-discovery.sh`, `.agents/scripts/tests/test-terminal-blocker-circuit-lifecycle.sh`. Run them unchanged; add coverage only where a required gate demands it.
- **Schemas/config:** queue entry JSON `{repo, issue, reason, opened_at, intake}` (`tbr_enqueue`, `terminal-blocker-recovery-helper.sh:323-326`) gains one intake value; no schema change.
- **Generated/deployed mirrors:** deployed copies under `~/.aidevops/agents/scripts/` refresh through `setup.sh` / `aidevops update`; nothing generated.
- **Migrations/backfills:** N/A with evidence: `rg -n "dispatch-exclusion-age" .agents/` finds no existing producer or reader, and the queue JSON gains only a new `intake` value that `tbr_enqueue` already stores verbatim, so there is no persisted data to migrate. Ordering: stamps start empty on deploy and accumulate per cycle, so the first escalation lands one threshold (default 24h) after deploy; no backfill is needed because currently stuck issues re-enter through the same per-cycle call sites.
- **Cleanup/rollback paths:** revert the PR; leftover age stamps are inert files. Queue entries with an unknown intake fall back to `local` (`tbr_enqueue` case default), so retire them by deleting entries with `intake == persistent_exclusion` under `${AIDEVOPS_BLOCKER_RECOVERY_DIR:-~/.aidevops/.agent-workspace/terminal-blocker-recovery}/queue/` (`TBR_ROOT`, `terminal-blocker-recovery-helper.sh:86`), or let `_tbr_check_entry` retire closed issues.

### Implementation Steps

1. Create `dispatch-exclusion-age-helper.sh` with `note <repo> <issue> <reason>` and `active <repo> <issue>`. The stamp holds `first_seen last_seen reason enqueued_reason`. If the reason matches and `now - last_seen` ≤ `AIDEVOPS_DISPATCH_EXCLUSION_GAP_SECONDS` (default 21600), only `last_seen` advances; otherwise the streak restarts. Once `last_seen - first_seen` ≥ `AIDEVOPS_DISPATCH_EXCLUSION_ESCALATE_SECONDS` (default 86400; 0 disables) and `enqueued_reason` differs, call `terminal-blocker-recovery-helper.sh enqueue <repo> <issue> <reason> persistent_exclusion` and store `enqueued_reason`. `active` returns 0 while `now - last_seen` ≤ gap. No network calls. Every failure returns 0 to the caller (best-effort, like the attention stamp).
2. Wire the two call sites (steps above). Source nothing new; invoke via `bash "${_PULSE_DISPATCH_LIB_DIR}/dispatch-exclusion-age-helper.sh" note ... >/dev/null 2>&1 || true` (or an equivalent sourced function). Keep each site to two or three lines so the surgical large-file exemption applies to the 2404-line `pulse-dispatch-lib.sh`.
3. Add `_tbr_check_exclusion_entry`. Retire (delete the entry and its decision) when `dispatch-exclusion-age-helper.sh active` fails (the filter stopped skipping it) or the issue lacks `auto-dispatch`. Otherwise apply `_tbr_decision_active` and `_tbr_print_entry ... persistent_exclusion` with public evidence only.
4. Prompt sentence (step 8 file): for `persistent_exclusion`, verify the named filter's cause on current issue/PR evidence. Repair a mechanical defect within existing authority: a stale lifecycle label, a superseded hold, a stale claim with no live owner, or a blocking dependency that is itself stuck (repair or dispatch that dependency). Otherwise post one decision packet naming the exact human input. Never grant permissions or approvals, and record exactly one decision per entry.
5. Run `shellcheck` on every changed shell file and the focused tests below. Then make a WIP commit before broad gates.

### Hazards and Compatibility

- **Concurrency/atomicity:** parallel dispatch rounds (t19116) may note the same issue concurrently. Write the stamp via `mktemp` + `mv -f` as `_dispatch_negative_cache_record` does (`pulse-dispatch-lib.sh:554-568`). A lost update only delays escalation by one cycle.
- **Migration/rollback:** additive; behaviour before the threshold is unchanged. Rollback leaves inert stamps.
- **Mixed-version/backward compatibility:** an older helper receiving `persistent_exclusion` normalizes it to `local` (`terminal-blocker-recovery-helper.sh:315-318`). Ship the helper and call sites in the same PR so producer and consumer stay matched.
- **Idempotency/retry:** one enqueue per (issue, reason) streak; `_tbr_decision_active` suppresses repeats after a recorded decision. A changed reason starts a new streak, which is intended, because the cause changed.
- **Partial failure/recovery:** unreadable stamps restart the streak (fail-safe: later, not wrong). Unreadable GitHub evidence in the checker returns 2 and keeps the entry, matching the existing checkers.

### Complexity Impact

- **Target functions:** `_dispatch_filter_consolidated_candidates` (about 60 lines, +3), `_dispatch_max_prefilter_cached_block` (15 lines, +4), `tbr_enqueue` (+0, case edit), `_tbr_check_entry` (about 100 lines, +4). That puts `_tbr_check_entry` at roughly 104% of the 100-line function gate.
- **Action required:** Extract helpers first for `_tbr_check_entry`. Fold the existing `unclassified_hold` / `answered_hold` / `unexplained_hold` dispatch (lines 1521-1528) and the new intake into one `_tbr_check_intake_entry` helper in `terminal-blocker-recovery-holds.sh`, so `_tbr_check_entry` shrinks rather than grows.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/dispatch-exclusion-age-helper.sh .agents/scripts/pulse-dispatch-lib.sh .agents/scripts/pulse-dispatch-lib-candidates.sh .agents/scripts/terminal-blocker-recovery-helper.sh .agents/scripts/terminal-blocker-recovery-holds.sh .agents/scripts/pulse-wrapper-cycle.sh
bash .agents/scripts/tests/test-pulse-dispatch-core-consolidated-label.sh
bash .agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh
bash .agents/scripts/tests/test-terminal-blocker-circuit-discovery.sh
bash .agents/scripts/tests/test-terminal-blocker-circuit-lifecycle.sh
# Production path: with AIDEVOPS_DISPATCH_EXCLUSION_ESCALATE_SECONDS=1 in a temp HOME, call `note` twice
# for one repo/issue a second apart, then confirm `terminal-blocker-recovery-helper.sh pending` lists it
# with intake persistent_exclusion (stub `gh` as the existing discovery test does).
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** shellcheck covers every changed script; the consolidated-label and failure-reason suites prove the two call sites keep their filter behaviour; the terminal-blocker suites prove existing intakes are unchanged; the temp-HOME run proves the streak → enqueue → pending path.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure changes.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: the commands above
- [ ] WIP commit created before broad gates: `wip: persistent dispatch exclusion intake`
- [ ] Evidence-triggered broad verification then run: not required — scoped change

### Scope Boundaries

**Hard boundaries:** do not change what any dispatch filter accepts or rejects; this task only ages and escalates its rejections. Never escalate `permission_grant_unverified`, `needs_maintainer_permissions` or `cost_budget_exceeded`. Never remove `needs-maintainer-review`, approval or permission labels. Make no GitHub writes from the new helper.

**AI brief owner:** the pulse supervisor for the terminal-blocker queue on the runner that observed the exclusion.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/dispatch-exclusion-age-helper.sh`
- `.agents/scripts/pulse-dispatch-lib-candidates.sh`
- `.agents/scripts/pulse-dispatch-lib.sh`
- `.agents/scripts/terminal-blocker-recovery-helper.sh`
- `.agents/scripts/terminal-blocker-recovery-holds.sh`
- `.agents/scripts/pulse-wrapper-cycle.sh`
- `.agents/reference/worker-integration-recovery.md`

## Acceptance Criteria

- [ ] An `auto-dispatch` issue skipped by the consolidated filter or a cross-cycle block for longer than `AIDEVOPS_DISPATCH_EXCLUSION_ESCALATE_SECONDS` appears exactly once in `terminal-blocker-recovery-helper.sh pending` with `"intake":"persistent_exclusion"` and the filter reason.

  ```yaml
  verify:
    method: codebase
    pattern: "persistent_exclusion"
    path: ".agents/scripts/terminal-blocker-recovery-helper.sh"
  ```

- [ ] The entry retires without a GitHub write once the filter stops skipping the issue for longer than the gap, or the issue closes or loses `auto-dispatch`.

  ```yaml
  verify:
    method: codebase
    pattern: "_tbr_check_exclusion_entry"
    path: ".agents/scripts/terminal-blocker-recovery-holds.sh"
  ```

- [ ] Negative: maintainer-gate reasons (`permission_grant_unverified`, `needs_maintainer_permissions`, `cost_budget_exceeded`) never produce a `persistent_exclusion` entry, and the dispatch filters' accept/reject results are unchanged (existing consolidated-label and failure-reason suites pass unchanged).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dispatch-core-consolidated-label.sh && bash .agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh"
  ```

- [ ] Negative: the mechanical `rearm` pass never prints or releases a `persistent_exclusion` entry.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-terminal-blocker-circuit-lifecycle.sh"
  ```

- [ ] Changed shell files are ShellCheck-clean, and `_tbr_check_entry` stays under the 100-line function gate.

## Context & Decisions

- Reuse the terminal-blocker queue instead of a new supervisor lane: it already triggers the supervisor (`pending --count`), dedupes via recorded decisions, and is the documented AI-brief-owner surface. Ruled out: a separate helper with its own LLM trigger (duplicate scheduling and dedupe).
- Age in a runner-local stamp written at the existing per-cycle log sites: zero API cost, and the filters already run every enumeration.
- Large-file holds are not a call site. The held issue leaves enumeration once `needs-simplification` is set, and its stall is the debt issue's own exclusion, which this task catches (as with #28476).
- `consolidated` stays escalatable even though `_dispatch_maintainer_gate_reason` lists it. A stale lifecycle label on a reopened issue is not a maintainer decision, and stage 0c declines to repair it by design.

## Relevant Files

- `.agents/scripts/pulse-dispatch-lib-candidates.sh:1626-1680` — consolidated enumeration filter and its per-cycle log line
- `.agents/scripts/pulse-dispatch-lib.sh:1724-1738` — cross-cycle negative-cache skip
- `.agents/scripts/pulse-dispatch-lib.sh:286-292` — maintainer-gate reason predicate
- `.agents/scripts/terminal-blocker-recovery-helper.sh:296-332,1420-1442,1488-1588` — enqueue, unclassified checker pattern, entry dispatch
- `.agents/scripts/pulse-dispatch-engine-supervisor.sh:173-226` — supervisor trigger from pending count
- `.agents/scripts/pulse-issue-reconcile-actions.sh:640-672` — stage 0c no-mutate rule for reopened consolidated issues

## Dependencies

- None blocking. Related: #39315 (t19174) fixes the stale-label instance that motivated this.
