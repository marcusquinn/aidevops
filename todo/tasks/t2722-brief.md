<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2722: Phase 1 — exhaustive inventory of auto-dispatch references

**Phase of:** t2721 / GH#20402
**Tier:** tier:thinking (scoping decision; informs all subsequent phases)
**Est:** 1h
**Behaviour change:** none (doc-only PR)

## Session origin

Interactive session continuation. Phase 1 of the 7-phase t2721 plan. Inventory must land before Phase 2+ can be confidently scoped.

## What

Produce `todo/tasks/t2721-inventory.md` — a comprehensive file-level enumeration of every code path, test, doc, workflow, and config that reads, writes, or asserts on the `auto-dispatch` label. Classify each reference by semantic role (writer, reader, assertion, doc, opt-out) and map it to the phase that will modify it.

## Why

Phase 1 is the scoping gate. Without a complete inventory:

- Phase 4's behaviour flip risks missing a positive-check code path, causing dormant issues or dispatch regression.
- Phase 5's scanner strip might leave label-adding logic in an unfamiliar scanner.
- Phase 6's self-assignment inversion might miss one of the three carveouts (t2157, t2218, t2406).
- Phase 7's doc sweep might leave teaching references that contradict the new behaviour.

The inventory is the "did I find everything" checklist the subsequent phases will tick against. Doing it as a first-class PR means it lands in the repo as a reference document, not an ephemeral chat artifact.

## How

1. `rg -l "auto-dispatch|auto_dispatch"` across `.agents/`, `.github/`, top-level docs.
2. Classify each file:
   - **WRITER** — adds the label (scanners, helpers, approval paths)
   - **READER** — checks label presence/absence (dispatch, self-assignment, triage)
   - **OPT-OUT** — references `no-auto-dispatch` (keep, not removing)
   - **DOC** — instructional prose (AGENTS.md, workflows, templates)
   - **TEST** — regression assertions
   - **WORKFLOW** — GitHub Actions YAML
3. For each writer and reader, record file:line and classify as positive (`"auto-dispatch"` label check) vs negative (`"no-auto-dispatch"` opt-out check).
4. Map doc inconsistency: which files teach "default on" vs "gated" vs silent.
5. Map test assertion direction: positive (asserts label present) vs negative (asserts label absent) vs semantic (asserts behaviour regardless of label).
6. Assign each reference to a phase (2-7) that will touch it.
7. Flag risks: references whose removal could break something subtle (e.g., the `gh-audit-log-helper.sh` query-for-analytics usage).

## Acceptance

1. `todo/tasks/t2721-inventory.md` exists with sections: Purpose, Writers, Readers, Opt-out (`no-auto-dispatch`) references, Self-assignment carveouts, Scanners, Docs, Tests, Workflows, TODO.md, Phase map, Risks, Open questions.
2. Every file returned by `rg -l "auto-dispatch|auto_dispatch" .agents/ .github/` is listed OR explicitly marked out-of-scope with rationale.
3. Each reference has a phase assignment (2, 3, 4, 5, 6, 7, or "keep").
4. Doc inconsistency is mapped with line-level evidence.
5. `TODO.md` has a `t2722` entry under `t2721` with `ref:GH#<child-issue>`.
6. Brief file at `todo/tasks/t2722-brief.md` (this file) committed.
7. PR body uses `Ref #20402` (parent) and `Closes #<this-child-issue>` (phase 1 issue).

## Files Scope

- `todo/tasks/t2721-inventory.md` — NEW: the deliverable
- `todo/tasks/t2721-brief.md` — NEW: parent brief (cross-cut with this PR)
- `todo/tasks/t2722-brief.md` — NEW: this brief
- `TODO.md` — EDIT: add t2722 entry
- `.agents/` — NONE (inventory reads; no behaviour change)
- `.github/` — NONE (inventory reads; no behaviour change)
