<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2868: P2c — inbox triage routine: sensitivity gate → classification → routing

## Pre-flight

- [x] Memory recall: "sensitivity classification routing local LLM" — none directly; this is novel
- [x] Discovery pass: depends on P0.5a (sensitivity detector) and P0.5c (Ollama) — neither merged yet; sequencing-blocked
- [x] File refs verified: pattern source `pulse-cleanup.sh` for routine structure
- [x] Tier: `tier:standard` — but high-risk path; consider tier:thinking if classification logic needs design work

## Origin

- **Created:** 2026-04-25
- **Session:** Claude Code interactive session (t2840 P2 phase)
- **Created by:** ai-interactive
- **Parent task:** t2840 / GH#20892
- **Conversation context:** Triage is the active component of the inbox. Without it, captured files just accumulate. Sensitivity-first is the hard rule — local LLM ALWAYS runs first; cloud LLM only after sensitivity classification clears. PII/privileged content NEVER reaches cloud.

## What

Implements `aidevops inbox triage` — the routine that processes captured items in `_inbox/`, classifies them, and routes to the appropriate plane. Runs via pulse (configurable interval, default hourly) or on-demand.

Triage flow per item:

1. **Sensitivity gate** (LOCAL ONLY — Ollama via P0.5c, never cloud): scan content for PII, privileged markers, competitive intel patterns. Stamp result.
2. **Plane classification** (local OR cloud per sensitivity tier): LLM proposes `{plane, sub-folder, metadata}`.
3. **Confidence check**: if confidence < 0.85, route to `_inbox/_needs-review/` with reason. Otherwise proceed.
4. **Route**: move file to target plane with stamped meta.json (sensitivity + classification provenance).
5. **Audit**: append routing entry to `triage.log` (status: `routed` or `needs-review`).

After completion:

- `aidevops inbox triage` processes all `pending` items in `_inbox/`.
- Sensitivity-classified items NEVER leak to cloud LLMs.
- Ambiguous items surface in `_needs-review/` for human inspection.
- `triage.log` records every routing decision with confidence + reasoning.

## Why

Without triage, capture is one-way — files dump in, never get sorted. With triage, the inbox becomes a working pipeline.

The sensitivity-first rule is non-negotiable: a screenshot of a privileged email arriving in `_inbox/scan/` must not be sent to a cloud LLM for classification — that's the leak we're preventing. P0.5a's local detector + P0.5c's Ollama substrate are the contractual prerequisites.

## Tier

**Selected tier:** `tier:standard`. The sensitivity gate logic comes from P0.5a; LLM routing helper from P0.5b; this task wires them together for inbox-specific flow. Worth re-evaluating to `tier:thinking` if reviewer judges classification heuristic design as substantial.

## PR Conventions

Child of parent-task t2840. Use `For #20892`.

## How

### Files to Modify

- `EDIT: .agents/scripts/inbox-helper.sh` — add `triage` subcommand.
- `NEW: .agents/scripts/inbox-triage-routine.sh` — pulse-callable entry point.
- `EDIT: .agents/configs/repos.json` schema (or per-repo config) — add `inbox_triage_interval_minutes` (default 60).

### Implementation Steps

1. `inbox-helper.sh triage [--dry-run] [--limit N]`:
   - Scan `_inbox/triage.log` for entries with `status: pending` (or scan filesystem for files older than N min)
   - For each item, run sensitivity gate FIRST:
     ```bash
     # P0.5a sensitivity detector — local-only
     sensitivity=$(sensitivity-detect.sh "$item_path")
     # Returns: public | confidential | privileged | competitive | unknown
     ```
   - If `unknown`: route to `_needs-review/` with reason "sensitivity-undetermined"
   - For non-`unknown`: pick LLM tier per `sensitivity-llm-routing.conf`:
     - `public` / `confidential` → cloud OK (use cheapest tier)
     - `privileged` / `competitive` → local LLM only (Ollama via P0.5c)
   - Run classification prompt with appropriate LLM:
     ```
     Given this content snippet, classify:
     - target_plane: knowledge | cases | campaigns | projects | feedback
     - sub_folder: <plane-specific path>
     - confidence: 0.0-1.0
     - reasoning: <one sentence>
     Respond as JSON.
     ```
   - If `confidence < 0.85`: route to `_needs-review/` with the LLM's reasoning
   - If `confidence >= 0.85`:
     - Move file to target plane path
     - Write `meta.json` adjacent: `{sensitivity, classification, confidence, reasoning, triaged_at, original_path}`
     - Append `triage.log` entry: `{status: "routed", from: "_inbox/...", to: "_<plane>/...", ...}`

2. `inbox-triage-routine.sh`:
   - Pulse-callable wrapper around `inbox-helper.sh triage`
   - Rate-limit: max N items per run (default 50) to avoid LLM cost spike
   - Backoff: if N consecutive `needs-review` results, log warning + halt (likely classifier issue)
   - Exit codes: 0 if all routed/needs-review cleanly, 1 if classifier errored

3. Wire into pulse: register routine in `pulse-wrapper.sh` task table with configurable interval.

4. `triage.log` schema extension:
   - Add `triaged_at`, `dest_plane`, `dest_path`, `confidence`, `reasoning`, `final_sensitivity` fields to existing JSONL.

### Complexity Impact

- **Target function:** none (new entry points and one extension to inbox-helper.sh)
- **Estimated growth:** ~250 lines new code total
- **Action required:** None.

### Verification

```bash
shellcheck .agents/scripts/inbox-helper.sh .agents/scripts/inbox-triage-routine.sh

# Sanity: privileged content stays local
echo "Subject: Re: legal advice from counsel" > /tmp/privileged.eml
aidevops inbox add /tmp/privileged.eml
aidevops inbox triage --dry-run --limit 1
# Expected: classified as `privileged`, LLM tier = local-only, never sent to cloud.
# Audit log shows tier:local in routing decision.

# Sanity: low-confidence routes to _needs-review
echo "vague text that could be anything" > /tmp/ambiguous.txt
aidevops inbox add /tmp/ambiguous.txt
aidevops inbox triage --limit 1
test -f _inbox/_needs-review/ambiguous_*.txt
```

### Files Scope

- `.agents/scripts/inbox-helper.sh`
- `.agents/scripts/inbox-triage-routine.sh`
- `.agents/configs/repos.json` (or per-repo config)

## Acceptance Criteria

- [ ] Sensitivity classification runs LOCALLY (Ollama) for every item BEFORE any cloud call.
- [ ] Items classified `privileged` / `competitive` are routed using local-only LLM tier.
- [ ] `_needs-review/` collects items with confidence < 0.85.
- [ ] Each routed item has adjacent `meta.json` with full provenance.
- [ ] `triage.log` records every decision with reasoning.
- [ ] Rate limit prevents cost spike (default max 50 items per pulse cycle).
- [ ] Smoke test demonstrates privileged-content-stays-local.

## Context & Decisions

- **Why local-first sensitivity, not parallel:** if sensitivity scanner runs in parallel with classifier, there's a window where classifier sees content before sensitivity stamp. That window is unacceptable for privileged content. Sequential gate eliminates the window.
- **Why 0.85 confidence threshold:** balances throughput (too high → everything goes to needs-review) against accuracy (too low → wrong-plane routing). Tunable via config.
- **Why rate limit:** uncontrolled inbox triage on a bulk import could hit LLM cost ceiling. 50/cycle * 60min cycle = 50/hr default ceiling.
- **Why audit log per decision:** if routing is wrong, user must be able to find the item. Without `triage.log`, items become unfindable.

## Relevant Files

- `.agents/scripts/sensitivity-detect.sh` (from P0.5a / t2846) — sensitivity detector
- `.agents/scripts/llm-routing-helper.sh` (from P0.5b / t2847) — tier routing
- `.agents/scripts/ollama-helper.sh` (from P0.5c / t2848) — local LLM substrate
- `t2866-brief.md` — directory contract
- `t2867-brief.md` — capture flow that produces pending items

## Dependencies

- **Blocked by:** t2846 (P0.5a — sensitivity detector), t2847 (P0.5b — LLM routing), t2848 (P0.5c — Ollama), t2867 (P2b — captures must produce pending items)
- **Blocks:** P2d (digest reads triage.log entries)
- **External:** Ollama installed and configured (workspace-level setup, not per-task)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | re-read P0.5 children once landed |
| Implementation | 4h | triage subcommand + routine + LLM prompt design + audit extensions |
| Testing | 2h | smoke tests for privileged-stays-local, low-confidence-routes-to-review, rate limit |
| **Total** | **~7h** | |
