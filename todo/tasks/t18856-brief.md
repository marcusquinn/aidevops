<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Local SEO: recurring monitoring and reporting SOPs (routine-ready, draft-only actions)

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `local SEO skills import subagent google business profile` → 0 hits — preferences stored this session (SEO Utils, DataForSEO/direct APIs)
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files; `.agents/seo/local-seo-routines.md` does not exist
- [x] File refs verified: 6 refs checked, all present at HEAD 83ee6cd5f0
- [x] Tier: `tier:standard` — SOP authoring inside decided routine and approval boundaries
- [x] Seeded draft PR decision recorded: skipped — depends on two sibling leaves landing first

## Origin

- **Created:** 2026-11-02
- **Session:** opencode:ses_e631bdc7cffe2C1iEoG8vJ7bBC
- **Created by:** ai-interactive (Build+), approved by maintainer
- **Parent task:** local SEO capability roadmap (see `Parent:` line on the issue)
- **Blocked by:** t18853 (#36481, `seo/local-seo.md`) and t18854 (#36482, geogrid metrics) — `blocked-by:t18853,t18854`; native GitHub blockedBy edges set at filing
- **Conversation context:** A reviewed third-party local SEO pack shipped 15 scheduled "tasks" (rank monitor, review velocity, GBP change monitor, citation audit, reports). Their cadence/approval structure is useful; their scheduler, vendor routing and ranking claims are not. aidevops already has routines (`reference/routines.md`) and approval handoff (`workflows/marketing-actions.md`).

## What

`NEW .agents/seo/local-seo-routines.md`: reusable SOPs that a user can wire into their own `TODO.md` `## Routines` (`agent:SEO` or a `run:` script) via `/routine`. Each SOP states purpose, suggested `repeat:` expression, inputs/targets kept separate from the SOP, evidence source, output path, approval boundary and failure handling. SOPs:

1. **Weekly geogrid snapshot** — SEO Utils GMB rank tracker if installed, else DataForSEO Maps grid recipe; compare only matching geometry; report ARP/ATRP/SoLV per definitions in `seo/seo-utils.md`.
2. **Review velocity and unanswered-review queue** (weekly) — GBP collector reviews; rolling baseline; reply drafts only.
3. **GBP profile change watch** (daily) — field diff against a stored baseline from the GBP collector. Never auto-overwrite the baseline on suspicious change; "not in our change log" means "needs review", not "unauthorised".
4. **Quarterly citation audit** (read-only) — inventory with URLs; substantive vs cosmetic differences; net changes since last audit.
5. **Monthly local report** — consume prior outputs (no new paid calls), render via `/report-render`; partial-data accounting; no causal claims without dated change logs.
6. **Multi-location rollup** (monthly) — reuse per-location outputs; list missing locations explicitly.

Add a pointer from `seo/local-seo.md` to the new file.

## Why

Without SOPs, users either hand-roll prompts that mix SOP, targets and schedule (an anti-pattern at `reference/routines.md:178`) or import a vendor-coupled task pack. These SOPs reuse existing data sources and the existing approval boundary.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No — SOP prose.
- [x] **Targets and reference pattern verified?**
- [ ] **No semantic or design decision remains?** Wording and thresholds remain.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:standard`

**Tier rationale:** SOP documentation inside decided routine/approval boundaries → tier:standard.

## PR Conventions

Leaf task: PR body uses `Resolves #<this issue>` and `For #<parent issue>`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Must cite files created by the two blocking siblings.
- **Status:** `not-created`
- **Freshness evidence:** file verification at HEAD 83ee6cd5f0
- **Verification run:** `UNVERIFIED — not run`
- **Stale-assumption warning:** Re-read `seo/local-seo.md` and `seo/seo-utils.md` "Geogrid metrics" after the blockers merge.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/reference/routines.md:1-60` — `## Routines` format, `repeat:` syntax, `agent:` vs `run:`.
- **Read first:** `.agents/reference/routines.md:171-178` — anti-patterns (keep SOP, targets and schedule independent).
- **Read first:** `.agents/workflows/marketing-actions.md` — approval/handoff boundary for drafts.
- **Read first:** `.agents/seo/local-seo.md` and the `## Geogrid metrics` section of `.agents/seo/seo-utils.md` (created by blockers).
- **Load only if:** `.agents/content/social-google-business-profile.md:66-123` — collector CLI and budgets when writing SOPs 2-3.
- **Stop when:** each SOP's data source, output and approval boundary is clear.

### Files to Modify

- `NEW: .agents/seo/local-seo-routines.md` — SOPs above; model on existing `seo/` leaf frontmatter (`description`, `mode: subagent`)
- `EDIT: .agents/seo/local-seo.md` — add a "Recurring work" pointer to `seo/local-seo-routines.md`
- `EDIT: .agents/subagent-index.toon` — regenerate with `subagent-index-helper.sh generate`

Per-SOP template to use:

```markdown
### <SOP name>
- **Suggested schedule:** `repeat:weekly(mon@07:00)` (user chooses in TODO.md)
- **Targets:** supplied by the routine entry or a private targets file — never embedded here
- **Evidence source:** <tool + file reference>
- **Output:** `~/.aidevops/.agent-workspace/work/seo-data/{domain}/local/<sop>/<date>.*`
- **Approval:** read-only | drafts held for `workflows/marketing-actions.md`
- **Failure handling:** PARTIAL with missing inputs listed; no retries that spend credits without approval
- **Do not:** <SOP-specific prohibitions>
```

### Complete Write Surface

- **Callers/readers:** `seo/local-seo.md` (pointer); users' `TODO.md` routine entries via `/routine` (`.agents/scripts/commands/routine.md`).
- **Writers/mutation paths:** documentation only; no routine is installed by this task. Output path convention reuses `seo.md:125` (`~/.aidevops/.agent-workspace/work/seo-data/{domain}/`).
- **Existing verification/tests:** `subagent-index-helper.sh check`, `linters-local.sh --changed`.
- **Schemas/config:** N/A because this is documentation-only; no `TODO.md` routine entries are added to this repo.
- **Generated/deployed mirrors:** `subagent-index.toon` regenerated; `setup.sh` deploys `.agents/`.
- **Migrations/backfills:** N/A because this is new-file-only documentation.
- **Cleanup/rollback paths:** revert the PR; N/A because documentation-only work leaves no state outside git.

### Implementation Steps

1. Wait for blockers to merge (dispatch gate handles this); re-read their outputs.
2. Write the six SOPs with the template. Mark review text and reviewer details as protected customer content (`content/social-google-business-profile.md:24`).
3. Add the pointer in `seo/local-seo.md`; regenerate the index.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — docs; blockers must merge first, so no concurrent edit of `seo/local-seo.md`.
- **Migration/rollback:** revert-only.
- **Mixed-version/backward compatibility:** no routine is enabled; existing users unaffected.
- **Idempotency/retry:** SOPs must say paid lookups are not retried automatically.
- **Partial failure/recovery:** SOPs specify PARTIAL outputs with missing inputs listed.

### Verification Before Dispatch

```bash
rg -n "^### " .agents/seo/local-seo-routines.md
rg -n "local-seo-routines" .agents/seo/local-seo.md .agents/subagent-index.toon
subagent-index-helper.sh check
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** first `rg` shows six SOP headings; second proves pointer + index; `check` validates the index; linter proves markdown.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** no routine installation, no new scheduler or brief-state system, no auto-posting of replies/posts, no account writes, no paid vendor default.

**AI brief owner:** maintainer interactive session (marcusquinn).

**Recovery:** preserve the current PR and use `reference/worker-discipline.md` runtime request when local recovery is unsafe.

### Files Scope

- `.agents/seo/local-seo-routines.md`
- `.agents/seo/local-seo.md`
- `.agents/subagent-index.toon`

## Acceptance Criteria

- [ ] `.agents/seo/local-seo-routines.md` contains the six SOPs, each with schedule, targets, evidence source, output, approval and failure handling.

  ```yaml
  verify:
    method: bash
    run: "test $(rg -c '^### ' .agents/seo/local-seo-routines.md) -ge 6"
  ```

- [ ] `seo/local-seo.md` links to the routines file.

  ```yaml
  verify:
    method: codebase
    pattern: "local-seo-routines"
    path: ".agents/seo/local-seo.md"
  ```

- [ ] Negative: no SOP publishes posts/replies, edits listings, or spends credits without an approval step, and none embeds targets in the SOP text.

  ```yaml
  verify:
    method: subagent
    prompt: "Does any SOP in .agents/seo/local-seo-routines.md publish, edit accounts, or spend paid credits without an explicit approval step, or embed specific client targets? PASS only if none."
    files: ".agents/seo/local-seo-routines.md"
  ```

- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Mirror cadence/approval ideas only; aidevops routines + marketing-actions replace the external scheduler and approval tiers.
- Per-location "brief" state files are not adopted; memory, routine state and output folders already cover it.

## Relevant Files

- `.agents/reference/routines.md:22-31` — routine entry format
- `.agents/reference/routines.md:178` — SOP/targets/schedule separation
- `.agents/seo.md:125` — seo-data output convention
- `.agents/content/social-google-business-profile.md:24` — review content is protected

## Dependencies

- **Blocked by:** t18853 (#36481) and t18854 (#36482)
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | routines, marketing-actions, blockers' outputs |
| Implementation | 1.5h | six SOPs + pointer |
| Verification | 10m | rg, index check, linter |
| **Total** | **~2h10m** | |
