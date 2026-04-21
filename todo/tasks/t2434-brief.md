<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2434: fix(upgrade-planning): preserve tasks across all 6 sections

## Pre-flight

- [x] Memory recall: "_upgrade_todo extraction TODO.md section" → 1 hit — just-stored lesson confirms 141-row Done drop; no broader prior fix.
- [x] Discovery pass: 0 open PRs, 0 commits touching `aidevops.sh:2595-2669` in last 48h. Prior merged fixes GH#17804 (Format leakage) and GH#17806 (### inside Backlog) both in same function but narrower scope.
- [x] File refs verified: `aidevops.sh:2595-2669` matches the function at HEAD; line ranges confirmed via Read.
- [x] Tier: `tier:standard` — multi-section extraction refactor plus test, single file touch plus a new test, not mechanical enough for simple.

## Origin

- **Created:** 2026-04-20
- **Session:** opencode interactive
- **Created by:** ai-interactive (during user request to upgrade planning templates on webapp + propertyservicesdirectory.com)
- **Conversation context:** User asked to upgrade 2 projects flagged by `aidevops update` (outdated planning templates). First run on webapp silently dropped 141 `[x]` completed tasks from `## Done` (extraction only covers `## Backlog`). Restored from `.bak` before proceeding. Fixing the bug before re-running the upgrades.

## What

`_upgrade_todo` (`aidevops.sh:2595-2669`) must extract and preserve tasks from all 6 template sections — `Ready`, `Backlog`, `In Progress`, `In Review`, `Done`, `Declined` — and re-insert each into its matching `<!--TOON:<tag>` marker in the new template. Today it only handles `Backlog`.

## Why

Reproduced 2026-04-20: `aidevops upgrade-planning --force` on webapp silently dropped 141 completed tasks from `## Done` (57 Backlog + 141 Done = 198 total → 57 only after upgrade). Completed-task rows carry `actual:` session time and `est:` breakdowns that only live in TODO.md — GitHub issues don't store these fields, so the audit trail is NOT reconstructable. Data was recovered from `.bak` before the working tree was committed, but the silent loss is the critical defect: any user following the recommended upgrade flow loses every task outside Backlog.

Adjacent prior fixes in the same function: GH#17804 (Format placeholder leakage), GH#17806 (### subsection preservation inside Backlog). Neither addressed cross-section extraction.

## Tier

**Selected tier:** `tier:standard`

**Rationale:** One function refactor in a ~1500-line shell script, plus a new regression test harness. Not a mechanical `oldString`/`newString` swap — requires understanding the existing section-skip logic and re-weaving it into a per-section loop. Standard Sonnet work.

## PR Conventions

Leaf issue — use `Resolves #20077` in PR body.

## How (Approach)

### Files to Modify

- EDIT: `aidevops.sh` — function `_upgrade_todo` (lines 2595-2669).
- NEW:  `.agents/scripts/tests/test-upgrade-planning-sections.sh` — regression test. Model on `.agents/scripts/tests/test-init-scope.sh` (same directory, similar scope: single-function test with synthetic fixtures).

### Implementation Steps

1. Replace single-section `awk` extraction (current lines 2604-2616, targeting `## Backlog`) with a per-section extraction helper invoked for each of the 6 sections. The helper takes `(file, section_name)` and returns the section body, preserving the existing skips:
   - Skip content inside `## Format` entirely.
   - Skip content inside triple-backtick code blocks.
   - Stop at the next `##` header.
2. Keep the post-extraction placeholder filter (lines 2619-2632) and apply it per-section.
3. Replace single-section re-insertion (current lines 2646-2666, targeting `<!--TOON:backlog`) with a loop over `(section → tag)` pairs:
   - `Ready → ready`
   - `Backlog → backlog`
   - `In Progress → in_progress`
   - `In Review → in_review`
   - `Done → done`
   - `Declined → declined`
   For each, insert the preserved content after the matching TOON marker's closing `-->`.
4. Emit a summary log line with the total task count merged (e.g. `Merged 198 tasks across 2 sections`).
5. Keep bash 3.2 compatible — no associative arrays, no `${var,,}`. Use parallel arrays or `case` dispatch.
6. Run `shellcheck aidevops.sh` — must stay clean.

### Verification

1. `shellcheck aidevops.sh` — clean.
2. New test: `bash .agents/scripts/tests/test-upgrade-planning-sections.sh` — passes.
   - Creates a synthetic TODO.md with tasks in all 6 sections (plus Format placeholders that must still be filtered).
   - Sources `aidevops.sh` to get access to `_upgrade_todo`.
   - Invokes the upgrade against a temp file.
   - Asserts every real task survives in its matching new-template section.
   - Asserts Format placeholders (tXXX/tYYY/tZZZ) are NOT promoted to real sections.
3. End-to-end: run `aidevops upgrade-planning --force` in `/Users/marcusquinn/Git/webapp` (local only, don't commit). Task count must match pre-upgrade (198). Revert the test run afterwards.

## Acceptance

- [ ] `_upgrade_todo` extracts tasks from all 6 sections.
- [ ] Tasks land in the matching `<!--TOON:<tag>` marker in the new template (not all dumped into Backlog).
- [ ] `## Format` placeholders and `tXXX`-style template IDs are still filtered out.
- [ ] New regression test covers all 6 sections plus Format-filter preservation.
- [ ] `shellcheck aidevops.sh` clean.
- [ ] Local end-to-end on webapp: `grep -cE '^- \[[ x-]\] t[0-9]' TODO.md` before == after (198).

## Out of Scope

- `_upgrade_plans` (extracts from first `###` header only — known limitation for free-form `##` plan content, separate issue if needed).
- Template version bump (v1.1 already published; this is a consumer-side fix).
