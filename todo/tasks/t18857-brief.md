<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# add-skill: content review for vendor/affiliate bias and unsupported claims before importing external skills

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `local SEO skills import subagent google business profile` → 0 hits — lesson stored this session: treat vendor-defaulting skill packs as affiliate plays
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h; `rg -i "affiliate|vendor bias|promotional" .agents/tools/build-agent .agents/scripts/commands/add-skill.md` → no matches
- [x] File refs verified: 4 refs checked, all present at HEAD 83ee6cd5f0
- [x] Tier: `tier:standard` — doc change with checklist wording to author
- [x] Seeded draft PR decision recorded: skipped — small doc change; worker composes wording

## Origin

- **Created:** 2026-11-02
- **Session:** opencode:ses_e631bdc7cffe2C1iEoG8vJ7bBC
- **Created by:** ai-interactive (Build+), approved by maintainer
- **Parent task:** none (framework improvement captured during the local SEO review)
- **Blocked by:** none
- **Conversation context:** Reviewing `garrettjsmith/localseoskills` showed vendor-first routing ("use it whenever connected", "cheapest", "90% of needs") to the author-promoted LocalSEOData, unsourced ranking claims, and review-gating advice. Maintainer: "many of these 'skills' are affiliate plays, we should be cautious of this in our reviews of them."

## What

The `/add-skill` workflow gains a **content review** step after the existing security scan (`.agents/scripts/commands/add-skill.md:46`), documented in `.agents/tools/build-agent/add-skill.md` as a new `## Content Review` section. The reviewer classifies each imported file as ADOPT / ADAPT / SKIP / REJECT using:

1. **Vendor and affiliate bias:** default routing to one paid tool; "use whenever connected" or "cheapest/only option" claims; referral links or codes; pricing/credit claims; author ownership of promoted tools (check README, licence, author links); inconsistent cost figures.
2. **Unsupported claims:** ranking or performance claims without a primary source; survey opinion stated as confirmed; correlation stated as cause; invented thresholds.
3. **Policy-violating tactics:** anything against the platform's published guidelines (example: review gating).
4. **Conflict with existing aidevops guidance:** list the conflicting file and keep ours unless the import brings primary evidence.
5. **Staleness:** deprecated features, APIs or roles.

Prefer extracting vetted workflows into native agents over wholesale import when items 1-3 are found. Record the outcome in the import's `skill-sources.json` `notes` field.

## Why

The existing scan (Cisco Skill Scanner) catches security problems, not commercial bias or mythical advice. Without a content review, imports can silently steer agents to paid vendors or guideline-violating tactics.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** No — wording to compose.
- [x] **Targets and reference pattern verified?**
- [x] **No semantic or design decision remains?**
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:standard`

**Tier rationale:** Decided content, but prose must be authored and kept concise → tier:standard.

## PR Conventions

Leaf task: PR body uses `Resolves #<this issue>`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Short doc edit; seed adds no value.
- **Status:** `not-created`
- **Freshness evidence:** file verification at HEAD 83ee6cd5f0
- **Verification run:** `UNVERIFIED — not run`
- **Stale-assumption warning:** If `add-skill-helper.sh` gains an automated review hook first, document that instead.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/commands/add-skill.md:46` — after step 4 (Security scan) insert step 5 **Content review** (one line pointing to `tools/build-agent/add-skill.md` "Content Review"); renumber Post-import to step 6
- `EDIT: .agents/tools/build-agent/add-skill.md:60` — insert `## Content Review` before `## Conflict Resolution` with the five checks and verdict scale above (≤25 lines)

### Complete Write Surface

- **Callers/readers:** `/add-skill` command doc (`.agents/scripts/commands/add-skill.md`) and its detail doc; `.agents/scripts/add-skill-helper.sh` is not changed.
- **Writers/mutation paths:** documentation only; `skill-sources.json` `notes` field already exists (`.agents/tools/build-agent/add-skill.md:93`).
- **Existing verification/tests:** `linters-local.sh --changed`; no tests cover these docs.
- **Schemas/config:** N/A because `skill-sources.json` schema is unchanged; only its existing `notes` field is used.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/`; `generate-skills.sh` output unaffected because no new agent file.
- **Migrations/backfills:** N/A because this is documentation-only; existing imports are not re-reviewed by this task.
- **Cleanup/rollback paths:** revert the PR; N/A because documentation-only work leaves no state outside git.

### Implementation Steps

1. Insert the command step and the `## Content Review` section as specified.
2. Keep wording generic (no named vendors); the local SEO pack may be cited as the motivating example in the PR body only.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — docs only.
- **Migration/rollback:** revert-only.
- **Mixed-version/backward compatibility:** helper behaviour unchanged; review is an agent step.
- **Idempotency/retry:** N/A — docs.
- **Partial failure/recovery:** N/A because documentation-only; a failed lint is fixed in place.

### Verification Before Dispatch

```bash
rg -n "Content review|## Content Review" .agents/scripts/commands/add-skill.md .agents/tools/build-agent/add-skill.md
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** `rg` proves both edits; linter proves markdown quality.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** documentation only; do not change `add-skill-helper.sh` or the security scanner.

**AI brief owner:** maintainer interactive session (marcusquinn).

**Recovery:** preserve the current PR and use `reference/worker-discipline.md` runtime request when local recovery is unsafe.

### Files Scope

- `.agents/scripts/commands/add-skill.md`
- `.agents/tools/build-agent/add-skill.md`

## Acceptance Criteria

- [ ] `/add-skill` workflow lists a content review step after the security scan.

  ```yaml
  verify:
    method: codebase
    pattern: "Content review"
    path: ".agents/scripts/commands/add-skill.md"
  ```

- [ ] `tools/build-agent/add-skill.md` has a `## Content Review` section covering vendor/affiliate bias, unsupported claims, policy violations, conflicts and staleness, with ADOPT/ADAPT/SKIP/REJECT verdicts.

  ```yaml
  verify:
    method: codebase
    pattern: "## Content Review"
    path: ".agents/tools/build-agent/add-skill.md"
  ```

- [ ] Negative: the security scan step and `--skip-security` semantics are unchanged.

  ```yaml
  verify:
    method: codebase
    pattern: "CRITICAL/HIGH blocks import"
    path: ".agents/scripts/commands/add-skill.md"
  ```

- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Generic wording keeps the rule applicable to any domain's skill packs.
- Ruled out: automated affiliate detection in `add-skill-helper.sh` (add later only with evidence of repeated misses).

## Relevant Files

- `.agents/scripts/commands/add-skill.md:41-47` — workflow steps
- `.agents/tools/build-agent/add-skill.md:60-67` — insertion point before Conflict Resolution
- `.agents/tools/build-agent/add-skill.md:93` — `skill-sources.json` notes field

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | two docs |
| Implementation | 20m | step + section |
| Verification | 5m | rg + linter |
| **Total** | **~35m** | |
