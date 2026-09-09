<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18427: Evaluate effort and delegation economics and document routing decision

## What

Execute the authorised bounded pilot when its controls/readiness pass, compare it with source-qualified production objective evidence, and commit a privacy-safe decision report. The outcome is a defensible retain/trial/recommend-change decision by workload class, not a preselected Max or low-effort winner.

## Why

The external screenshots suggest higher effort can reduce actions and cost, but our historical Max sample had only five sessions and very different context sizes. Current defaults are also a reversible educated choice, not a proven optimum. The preceding leaves make the relevant economic and acceptance evidence available.

## Origin

Created 2026-09-10, interactive auto-dispatch brief. Parent: t18422. Blocked by t18426 (`blocked-by:t18426`). User authorised this optimisation programme; authority is restricted by the explicit ceilings and provider/privacy constraints below.

## Pre-flight

- [x] Memory recall: model effort/delegation economics — no relevant hits.
- [x] Discovery pass: existing scorecard, replay harness and current routing policy reviewed; no related open PR or duplicate open implementation issue found.
- [x] File refs verified: existing efficiency entry point, replay CLI/workflow and routing policy exist; new prerequisite protocol/config/report fields are explicitly future outputs of t18423–t18426 and must be verified after their merges.
- [x] Tier: thinking — independent evidence synthesis and economic adoption judgment are the task.
- [x] Seeded draft PR decision recorded: skipped; a report cannot be seeded with unobserved findings.

## Tier

**Selected tier:** `tier:thinking`. Do not promote the entire worker to an arbitrary concrete model: runtime routing selects its configured thinking route. Experimental candidate models are scoped to the sealed pilot, not worker availability fallbacks.

## How

### Files to Modify

- `NEW: .agents/reference/model-effort-evaluation.md` — dated aggregate decision report and reproducible evidence fingerprints.
- `EDIT: .agents/reference/model-effort-pilot.md` — append protocol outcomes/limitations; this predecessor output must exist before pickup.
- `EDIT: .agents/tools/context/model-routing.md` — link the decision report and evidenced limitations.
- `EDIT: .agents/reference/agent-routing.md` — link delegation evidence without always-loaded instruction bulk.

### Files Scope

- `.agents/reference/model-effort-evaluation.md`
- `.agents/reference/model-effort-pilot.md`
- `.agents/tools/context/model-routing.md`
- `.agents/reference/agent-routing.md`

### Complete Write Surface

- **Callers/readers:** `report-token-use-helper.sh`, `brief-tier-test-helper.sh` and predecessor `model-effort-pilot.md` provide the approved observation/execution paths.
- **Writers/mutation paths:** `model-effort-evaluation.md` and linked docs contain public aggregates; existing replay writes private cells/results only within the sealed programme.
- **Tests/fixtures:** `model-effort-pilot.md` specifies the predecessor's qualified fixtures and dry-run receipt checks; report arithmetic is independently recomputed.
- **Schemas/config:** `model-effort-pilot.json` is consumed, not broadened; no routing-table or provider/account configuration mutation.
- **Generated/deployed mirrors:** `setup.sh` remains untouched; rebuild private artifacts from the public recipe rather than reading another runner's private directories.
- **Migrations/backfills:** N/A because evaluation consumes existing producer fields/plans and never rewrites historical telemetry.
- **Cleanup/rollback paths:** `brief-tier-test-helper.sh` owns disposable cell cleanup; preserve evidence and revert only public report edits if needed.

### Implementation Steps

1. Verify predecessor merges, exact recipe fingerprints, runtime/model availability and observation coverage. Capture a fixed production window with the t18425 read-only report. Separate workload classes, objective quality, cache/context bands, policy/runtime versions and parent/child populations. Incomplete cohorts remain visible, not silently discarded.
2. Rebuild the qualified pilot from the public metadata and seal predictions before inference. Use only existing approved OpenAI ChatGPT OAuth. No API-key billing, new accounts/providers, forced quota resets or auth changes. Retain enforced sandbox/egress; missing authority/control is a blocker, not permission to use trusted-local or a test backend.
3. Enforce the shared maximum of 24 launched cells (including failed launches, canaries, retries and confirmations), 180 seconds/cell, 90 minutes total programme wall time and one concurrent cell. Do not enlarge these ceilings, automatically restart a spent programme or claim they are dollar/quota caps. Account for ambiguous attempts conservatively and reuse completed evidence on resume.
4. Compare Astra efforts with model/harness/cases fixed, then compare the candidate against Sol-medium. Record actual observed effort and usage; unsupported/mismatched effort fails the cell rather than being relabelled. Retain failures and no-progress/repair work. Cache state and reconstructed/contaminated inputs are explicit confounders.
5. Analyse total estimated cost per verified objective, quality/acceptance rate, elapsed and active time, repair, intervention and independent sample counts. Never substitute per-minute burn, tokens/response, host exits or number of tool calls for verified outcomes. Quota observations, if available through existing aggregate tooling, remain separate and unattributable when accounts are shared.
6. Compare delegation's accepted contribution against parent integration/repair from production; do not assert a causal subagent-policy improvement from unmatched sessions. Replay disables aidevops plugins/subagents, so it cannot establish end-to-end aidevops superiority. Do not remove safety/domain guidance or invent a new harness to force that conclusion.
7. Publish the actual evidence and recommendation: retain, bounded task-class trial, or proposed separately reviewed default change. Small, quarantined, conflicting or insufficient evidence can legitimately yield retain-with-specific-next-evidence. No default change is implemented here; the report supplies exact affected policy/config paths, expected benefit, risks and verification for any future approved change.

### Hazards and Compatibility

- **Concurrency/atomicity:** One cell at a time and a shared sealed programme budget; observation windows are fixed before comparison.
- **Migration/rollback:** No migrations/default changes; report amendments preserve prior evidence and executed seals.
- **Mixed-version/backward compatibility:** Segment runtime/policy/effort sources and distinguish isolated replay from production; no pooled causal claim across unmatched groups.
- **Idempotency/retry:** Reuse completed cells and count ambiguous/failed attempts; never refresh budget by rerunning the programme.
- **Partial failure/recovery:** Keep unknown coverage and blockers explicit; preserve private logs and publish only aggregate hashes, never raw paths/account/session identities.

### Verification Before Dispatch

Existing entry points (rebuild private arguments from the predecessor recipe):

```bash
.agents/scripts/report-token-use-helper.sh efficiency --since 7d --json
bash .agents/scripts/brief-tier-test-helper.sh --help
.agents/scripts/linters-local.sh --changed
```

Run the predecessor's exact qualification/dry-run checks before any real `run`, then verify each result against its seal, effective model/effort evidence and deterministic acceptance. Recompute report arithmetic independently from retained results; report sample counts and unallocated/missing coverage. Review documentation diff for private data and unsupported performance claims. No inference has been run as part of authoring this brief.

- **Surface mapping:** Efficiency CLI supplies production coverage; replay help/qualified recipe supplies bounded execution; seal/receipt checks establish actual model and deterministic outcomes; arithmetic/privacy review and changed-file lint verify the public decision report.

### Progressive Context Plan

Read the predecessor recipe and scorecard coverage first. Load only relevant sealed result summaries and routing rationale for the compared task class; keep raw logs out of context unless a concrete failed cell requires diagnosis. Stop when the recommendation and its uncertainty can be traced to actual observations.

## Acceptance Criteria

- [ ] The bounded pilot has terminal, source-qualified results and a privacy-safe report, including failures and consumed budget; missing gates do not count as a successful pilot.
- [ ] The report distinguishes isolated replay from production aidevops and evaluates parent+child+repair economics where coverage permits.
- [ ] A defensible workload-specific retain/trial/recommend-change decision is committed; uncertain evidence is explicit and no shared routing/account/sandbox setting changes.

## Safety-Stop Recovery and Seeded Draft PR

No seed. If authentication, egress, observation or a budget fuse blocks execution, checkpoint the exact task/run IDs, seal, completed cells, remaining acceptance criteria, remaining budget and required unblock evidence. Keep the experiment criterion open and the issue blocked; do not call a skipped experiment completed or ask the worker to weaken a control. Resume only the remaining authorised cells after the prerequisite is verified. Release or deployment is not authorised by this task.
