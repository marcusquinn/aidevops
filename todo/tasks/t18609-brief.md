## Task


`_enrichment_run_worker` must report success only when this enrichment run actually added a Worker Guidance section. Today it reports success whenever the post-run body contains the substring `Worker Guidance`.

## Done when

- [ ] Success requires the body to change and to gain a Worker Guidance heading.
- [ ] Negative: an issue whose body already contained Worker Guidance before the run is never reported as successfully enriched when the run leaves the body unchanged, and the bare substring check never remains.
- [ ] `shellcheck` is clean, and `test-worker-outcome-routing.sh` passes.

<details>
<summary>Worker implementation contract</summary>

## Worker Guidance


### Files to Modify

- `EDIT: .agents/scripts/pulse-quality-debt.sh:350-388` — in `_enrichment_run_worker`:
  - fetch `pre_body` (same `gh issue view ... --json body` call as lines 378-379) before launching the runtime;
  - after the run, success requires `post_body != pre_body` **and** the count of `Worker Guidance` headings in `post_body` to be greater than in `pre_body` (count with `grep -c '^#\+ Worker Guidance'` on each body);
  - log the outcome as now: success line, or the `worker ran (exit=N) but no new Worker Guidance` line.

Skeleton:

```bash
local pre_body="" pre_count=0 post_count=0
pre_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body --jq '.body // ""' 2>/dev/null) || pre_body=""
pre_count=$(printf '%s\n' "$pre_body" | grep -c '^#\{1,6\} Worker Guidance' || true)
# ... run worker ...
post_count=$(printf '%s\n' "$post_body" | grep -c '^#\{1,6\} Worker Guidance' || true)
if [[ "$post_body" != "$pre_body" && "$post_count" -gt "$pre_count" ]]; then
```

### Complete Write Surface

- **Callers/readers:** `dispatch_enrichment_workers` (`pulse-quality-debt.sh:474`) uses the return code only for `enriched_total`.
- **Writers/mutation paths:** none new; read-only `gh issue view`.
- **Existing verification/tests:** `.agents/scripts/tests/test-worker-outcome-routing.sh` (enrichment routing), `.agents/scripts/tests/test-pulse-wrapper-worker-count.sh` (stubs).
- **Schemas/config:** N/A — no persisted state change (`_ff_mark_enrichment_done` runs regardless of success, line 481).
- **Generated/deployed mirrors:** deployed `~/.aidevops/agents/scripts/` via `setup.sh`.
- **Migrations/backfills:** none needed. Searched `fast-fail-counter.json` writers (`pulse-fast-fail.sh:976`, `headless-runtime-failure.sh:1668`); success is not persisted, only logged to `$LOGFILE` and counted in `enriched_total`.
- **Cleanup/rollback paths:** the existing `push_cleanup` entries in `_enrichment_run_worker` (`.agents/scripts/pulse-quality-debt.sh:357-363`) still remove the prompt and output files; `pre_body` is a local variable that needs no cleanup. Rollback: revert the PR.

### Implementation Steps

1. Add the pre-run body fetch and heading count.
2. Replace the substring check with the decided rule.
3. Run `shellcheck` and the existing tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** a human edit during the run could cause a false success only if it adds a Worker Guidance heading. This is acceptable.
- **Migration/rollback:** code-only.
- **Mixed-version/backward compatibility:** N/A — single process.
- **Idempotency/retry:** unchanged. Enrichment is marked done regardless.
- **Partial failure/recovery:** if the pre-body fetch fails, `pre_body=""`. The check then degrades to the current behaviour, which is acceptable and should be logged.

### Complexity Impact

- **Target function:** `_enrichment_run_worker` in `.agents/scripts/pulse-quality-debt.sh`
- **Current line count:** 39 lines
- **Estimated growth:** +6 lines
- **Projected post-change:** ~45 lines (more if the sibling env-contract task lands first; extract `_enrichment_guidance_added` if it exceeds 80)
- **Action required:** Watch.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-quality-debt.sh
bash .agents/scripts/tests/test-worker-outcome-routing.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** shellcheck covers syntax. The routing test covers the caller contract.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** none beyond framework safety guarantees. Do not change when `_ff_mark_enrichment_done` is called.

**AI brief owner:** interactive maintainer session that filed this issue.

**Recovery:** preserve the current PR and use the structured runtime request in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-quality-debt.sh`

</details>

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

<!-- aidevops:brief-schema=v2 -->


## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse enrichment` → 0 hits — no relevant lessons
- [x] Discovery pass: 0 merged / 0 open PRs touching `_enrichment_run_worker` success detection
- [x] File refs verified: 3 refs checked, all present at HEAD `90631c51d`
- [x] Tier: `tier:standard` — single-function change with a decided rule; no exact diff supplied
- [x] Seeded draft PR decision recorded: skipped — small change

## Origin

- **Created:** 2026-10-07
- **Session:** opencode:unknown-2026-10-07
- **Created by:** ai-interactive
- **Conversation context:** While verifying the enrichment pipeline, the only "successfully added Worker Guidance" log line turned out to be false.

## What

`_enrichment_run_worker` must report success only when this enrichment run actually added a Worker Guidance section. Today it reports success whenever the post-run body contains the substring `Worker Guidance`.

## Why

`.agents/scripts/pulse-quality-debt.sh:381` checks `[[ "$post_body" == *"Worker Guidance"* ]]`. Issue bodies composed by issue-sync already contain a top-level `### Worker Guidance` block: `_compose_issue_worker_guidance` promotes the brief's `## How` section into it (see the HEADING LOCK comment in `.agents/templates/brief-template.md`).

Evidence:

- pulse log: `Enrichment: successfully added Worker Guidance to #11499 in awardsapp/awardsapp`;
- the issue body of #11499 contains `### Worker Guidance` at line 3;
- GraphQL `userContentEdits` shows the last body edit at 2026-10-04T06:59:45Z;
- the fast-fail entry that triggered enrichment is dated 2026-10-04T07:24:59Z, so the body was not edited by enrichment;
- at the same time, every enrichment worker was aborting before model launch (sibling task).

As a result, the pipeline reports success that never happened, and every brief-composed issue would count as enriched no matter what the worker did.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Rule and skeleton only.
- [x] **Targets and reference pattern verified?**
- [x] **No semantic or design decision remains?** The rule is decided below.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:standard`

**Tier rationale:** Decided rule in one function, without an exact diff.

## PR Conventions

Leaf task: the PR body uses a closing keyword for this issue.

## Context & Decisions

- Matching a unique marker appended by the enrichment prompt was considered. A heading-count delta needs no prompt change and still works when the worker appends a second Worker Guidance section.

## Relevant Files

- `.agents/scripts/pulse-quality-debt.sh:381` — current substring check
- `.agents/scripts/pulse-quality-debt.sh:286-326` — enrichment prompt (asks the worker to append `## Worker Guidance`)

## Dependencies

- **Blocked by:** none (independent; touches the same function as the env-contract sibling, so expect a trivial rebase)
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | one function |
| Implementation | 20m | pre-fetch and comparison |
| Verification | 15m | shellcheck and tests |
| **Total** | **45m** | |

</details>

<details>
<summary>Brief workflow contract</summary>

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued auto-dispatch work must pass its `Dispatch Readiness Contract (brief schema v2)`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria.

</details>

---
*Synced from TODO.md by issue-sync-helper.sh*

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.38.23 plugin for [OpenCode](https://opencode.ai) v1.18.34 with claude-opus-5-5 spent 1h 59m and 31,481 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABVj2ObA",
  "title": "t18609: fix(pulse): enrichment success check is a false positive when the brief already has Worker Guidance",
  "updatedAt": "2026-10-09T03:00:49Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/33879",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18609",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "33879",
  "captured_at": "2026-10-09T21:16:09Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
