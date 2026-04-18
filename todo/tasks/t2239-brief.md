<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2239 — Add opus-4.7 as top auto-escalation rung + `model:opus-4-7` opt-in label

## Session origin

Interactive. Designed in conversation with the maintainer after
discussing whether to wire 4.7 as an escalation rung. Initial agent
recommendation (keep 4.7 opt-in only, based on MRCR long-context
regression) was revised after the maintainer pointed out that
observed 4.7 behaviour on long-running agentic work is better than
4.6 — and MRCR is a cold-retrieval test, not an agentic-coherence
test.

## What

Two related changes to the cascade dispatch model:

1. **Auto-escalation extension.** Add a 4th rung above `tier:thinking`
   (opus-4.6). When opus-4.6 fails its escalation threshold, apply the
   `model:opus-4-7` label and re-dispatch. Only after opus-4.7 also
   fails does the issue escalate to NMR.

2. **Opt-in label `model:opus-4-7`.** A label that routes a dispatch
   directly to opus-4.7, bypassing tier resolution. Used
   intentionally by the maintainer for short-context high-reasoning
   tasks where the SWE-Bench gains and `xhigh` effort level outweigh
   the MRCR regression and tokenizer bloat.

Plus housekeeping: update stale 4.6 context references (some still
say 200K; runtime configs already have 1M).

## Why

- `tier:thinking` currently terminates at opus-4.6. A task that
  exhausts 4.6's retries goes straight to NMR (human review) with
  no further autonomous attempt. If 4.7 handles long-running
  agentic work better — as observed — there is one more
  autonomous rung available before burning maintainer attention.
- The MRCR v2 regression (256K: 91.9% → 59.2%, 1M: 78.3% →
  32.2%) is a cold-retrieval test: pre-load a large context,
  ask needle questions. Workers don't do that — they build
  context incrementally through tool calls. Agentic coherence
  is a different axis and the observed signal there favours 4.7.
- The opt-in label covers the cases where the maintainer knows
  up-front that a task is short-context, high-reasoning (security
  audits on a small brief, architecture calls on a contained
  module, hi-res vision work). Routing these to 4.7 directly
  skips an opus-4.6 attempt that would add no value.
- Stale 4.6 context references (200K in compare-models-helper.sh,
  "200K tokens (1M beta)" in models-opus.md) contradict the
  runtime config which has had 1M for some time. Docs and
  scripts should agree with what's actually running.

## How

### Files to Modify

- **EDIT**: `.agents/scripts/compare-models-helper.sh:154` — change
  4.6 context from `200000` to `1000000` in the `MODEL_DATA`
  TSV row. (Already 1M in runtime config; this is a stale ref.)

- **EDIT**: `.agents/tools/ai-assistants/models-opus.md:55-89` —
  change 4.6 context row from "200K tokens (1M beta)" to
  "1M tokens, 800K auto-compact". Rewrite the `## Opus 4.7
  (opt-in)` section to match the revised position: MRCR is a
  cold-retrieval signal; agentic coherence matters for workers;
  4.7 is now wired as the top auto-escalation rung AND available
  as opt-in via `model:opus-4-7`. Keep the MRCR and tokenizer
  data as "when this matters vs when it doesn't".

- **EDIT**: `.agents/scripts/worker-lifecycle-common.sh:855-879` —
  extend the case statement in `escalate_issue_tier`. Current
  behaviour: `tier:thinking` terminates the cascade. New
  behaviour: `tier:thinking` without `model:opus-4-7` escalates
  to `model:opus-4-7` (same `tier:thinking` label retained).
  `tier:thinking` WITH `model:opus-4-7` terminates (cascade
  exhausted, hand off to NMR). Use the existing label-add
  mechanism (`gh issue edit --add-label model:opus-4-7`).

- **EDIT**: `.agents/scripts/pulse-model-routing.sh:29-49` —
  add a label check before the tier-based resolution. If
  the labels CSV contains `model:opus-4-7`, bypass tier
  resolution and return `anthropic/claude-opus-4-7` directly.
  This makes the label both the opt-in switch AND the cascade
  target.

- **EDIT**: `.agents/configs/model-routing-table.json` — add
  a top-level `model_overrides` entry or inline note
  documenting that `model:opus-4-7` is the label-override
  path. (Pure documentation; routing logic lives in the
  shell script.)

### Reference pattern

- **Existing cascade logic**: `worker-lifecycle-common.sh:814-880`
  is the function to extend. The case statement at line 855
  is where the new branch goes. Notice the existing branches
  follow a consistent shape: set `current_tier`, `next_tier`,
  `next_label`, `remove_label`. The new `tier:thinking +
  model:opus-4-7 → terminate` branch returns 0 (cascade done).
  The `tier:thinking (no model override) → add model:opus-4-7`
  branch adds the label without removing the tier label.

- **Existing label-check pattern**: `pulse-model-routing.sh:35-39`
  uses a `case ",${labels_csv},"` pattern. New check follows the
  same pattern, placed BEFORE the tier case.

### Verification

1. `shellcheck .agents/scripts/worker-lifecycle-common.sh .agents/scripts/pulse-model-routing.sh` — zero violations.
2. `markdownlint-cli2 .agents/tools/ai-assistants/models-opus.md` — zero violations.
3. New test `.agents/scripts/tests/test-opus-47-cascade.sh`:
   - Issue with `tier:thinking` and no `model:opus-4-7`, failure count = threshold → `escalate_issue_tier` should add `model:opus-4-7` label (no tier label change).
   - Issue with `tier:thinking` and `model:opus-4-7`, failure count = threshold → `escalate_issue_tier` should return 0 without label mutation (terminal).
   - `resolve_dispatch_model_for_labels "tier:standard,model:opus-4-7"` should return `anthropic/claude-opus-4-7` (label override wins over tier).
   - `resolve_dispatch_model_for_labels "tier:thinking"` should still return `anthropic/claude-opus-4-6` (unchanged default).
4. Existing cascade tests (`test-tier-label-ratchet.sh`) must still pass — the new case is additive, not a rewrite of earlier branches.

## Acceptance Criteria

- [ ] `compare-models-helper.sh` 4.6 context row reads `1000000`.
- [ ] `models-opus.md` 4.6 context row reads "1M tokens, 800K auto-compact" (no more "beta").
- [ ] `models-opus.md` has a clear "when to apply `model:opus-4-7`" and "when NOT to apply" section.
- [ ] `escalate_issue_tier` adds `model:opus-4-7` to a failing `tier:thinking` issue on threshold boundary.
- [ ] `escalate_issue_tier` returns 0 (no mutation) on a `tier:thinking + model:opus-4-7` issue (NMR takes over).
- [ ] `resolve_dispatch_model_for_labels` honours `model:opus-4-7` label and returns `anthropic/claude-opus-4-7`.
- [ ] Label override takes precedence over tier label (matters when both are present, e.g. `tier:standard + model:opus-4-7`).
- [ ] New test `test-opus-47-cascade.sh` passes.
- [ ] Existing `test-tier-label-ratchet.sh` still passes.
- [ ] Shellcheck zero violations.
- [ ] Markdownlint zero violations on edited doc.

## Context & Decisions

- **Why a `model:opus-4-7` label and not a new `tier:*` label.**
  Tiers are capability classes (simple/standard/thinking).
  Adding a 4th tier conflates "capability class" with "specific
  model choice." A model-override label is cleaner: the label's
  name documents what it does, and it composes with the existing
  tier labels instead of replacing them.

- **Why the auto-cascade adds the label instead of replacing
  `tier:thinking`.** Keeping `tier:thinking` makes the history
  of the cascade readable on the issue: the labels show the
  path through the ladder rather than only the terminal state.

- **Why the label takes precedence over tier resolution.**
  An opt-in label is an explicit maintainer choice; the
  resolver should respect it unambiguously. Making it take
  precedence also simplifies the cascade-added case: once
  `escalate_issue_tier` adds the label, the next dispatch
  routes to 4.7 without any further case-by-case logic
  in the tier resolver.

- **Out of scope.** Evaluating whether 4.7 should replace
  4.6 as the `tier:thinking` default. That's a bigger change
  requiring a bake-in period on real worker dispatches with
  the new opt-in path. This task sets up the mechanism; we
  gather evidence before considering the larger migration.
