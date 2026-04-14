<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2068: New-file qlty smell gate — block PRs adding new source files that ship with smells

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** The top smell contributors (`higgsfield/*.mjs`, `.agents/plugins/opencode-aidevops/*.mjs`, `.opencode/lib/toon.ts`) all entered the repo already complex. Nothing in the ratchet ever required a *new* file to be smell-free before landing. Subsystems arrive as 300-line mega-modules and nobody refactors because "it worked when it landed".

## What

Add a CI check that runs `qlty smells --all --sarif` *against just the files newly added in the PR* (via `git diff --name-only --diff-filter=A origin/main...HEAD`). If any newly-added source file (`.py`, `.mjs`, `.js`, `.ts`, `.sh`, `.rb`, etc. — delegate the filter to qlty's own language detection) reports **any** smell, fail the check unless the PR carries a documented justification label.

This is narrowly scoped: it only checks files that are brand-new in the PR. Existing files are not re-checked (that's covered by t2065's regression gate). The point is to prevent debt accumulation from new subsystems.

## Why

- **Historical pattern:** every top-5 smell file in the current snapshot was a new file at some point. The higgsfield video subsystem landed in a single PR adding `higgsfield-video.mjs` (1500+ lines, cyclomatic chaos). The opencode plugin cluster landed similarly. None had a simplification step before they landed — they shipped complex and stayed complex.
- **Early-stage refactor is free.** A function with cyclomatic 25 at PR time is easy to split — the author still has the context in their head. Three months later, nobody remembers why it's shaped that way and everyone leaves it alone.
- **The existing file-size gate is insufficient.** It only checks shell, it counts lines not complexity, and it only fires at 1500+ lines. A 400-line Python file with cyclomatic 40 sails through.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Requires CI design, awareness of qlty language detection, override-label handling, and careful scoping (don't break PRs that add fixtures, vendored code, generated files, or templates). Opus-tier design work.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Files to Modify

- `NEW: .github/workflows/qlty-new-file-gate.yml` — or as an additional job in `qlty-regression.yml` (from t2065) if cleaner
- `NEW or EDIT: .agents/scripts/qlty-regression-helper.sh` — add `new-files` subcommand that only scans newly-added files
- `EDIT: .agents/AGENTS.md` — document the override label `new-file-smell-ok` and required justification

### Implementation Steps

1. **Decide placement.** If `qlty-regression.yml` from t2065 already exists, add this as a second job in the same workflow (shared qlty install). If not, separate workflow.

2. **Detect new files.** `git diff --name-only --diff-filter=A origin/main...HEAD` returns added paths. Filter out:
   - Anything matching qlty's existing `exclude_patterns` in `.qlty/qlty.toml` (tests, vendor, generated, templates, etc.)
   - Explicit new-file exclusions for docs: `*.md`, `todo/**`, `.github/**` non-workflow
   - Fixture paths matching `**/fixtures/**`, `**/testdata/**` (already in qlty's exclude set)

3. **Run qlty against the filtered list.** `~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet <file1> <file2> ...` — qlty accepts path arguments. Parse the result, count smells per file.

4. **Fail if any new file has any smell.** Per-file breakdown in the PR comment:

   ```
   New file(s) shipped with qlty smells:
   - `path/to/new-file.py`: 4 smells
     - qlty:function-complexity (cyclomatic 28): parse_envelope at line 45
     - qlty:file-complexity: total 87
     - qlty:return-statements: process_row at line 112 (6 returns)
     - qlty:nested-control-flow: parse_envelope at line 67 (depth 5)
   ```

5. **Override label `new-file-smell-ok`.** Requires the PR description to contain a `## New File Smell Justification` section. The workflow greps for the section; failing that, fails the check even with the label.

### Verification

```bash
# Workflow lints
actionlint .github/workflows/qlty-new-file-gate.yml

# Helper has new subcommand
.agents/scripts/qlty-regression-helper.sh new-files --base HEAD~5 --head HEAD --dry-run

# Smoke test: throwaway PR adding a deliberately smelly new file fails the check
```

## Acceptance Criteria

- [ ] New workflow (or added job) runs on PR events and scans only newly-added files
- [ ] Helper supports `new-files` subcommand that returns per-file smell breakdown
- [ ] PRs adding files with qlty smells fail the check unless `new-file-smell-ok` label + justification section present
- [ ] PRs touching only existing files (no new files) skip this check and pass
- [ ] PRs adding doc/fixture/template files (matching qlty exclude patterns) skip this check
- [ ] AGENTS.md documents the override label and justification requirement
- [ ] `actionlint` passes

## Context & Decisions

- **Why an override label at all?** Because some legitimate new files ship complex: generated code, vendored third-party, fixtures that mirror real-world shapes. The override exists for those, with justification required in the PR body so maintainers can push back on abuse.
- **Why only new files, not modified files?** Modified files are covered by the t2065 regression gate (delta-based). This gate fills the specific "brand-new subsystem lands already smelly" gap.
- **Why not fail on existing-file modifications that add smells?** That's literally t2065. Keep the two gates narrow and orthogonal.

## Relevant Files

- `.github/workflows/qlty-regression.yml` — sibling workflow from t2065 (may be the same file)
- `.agents/scripts/qlty-regression-helper.sh` — sibling helper from t2065
- `.qlty/qlty.toml` — existing exclude patterns to honour

## Dependencies

- **Blocked by:** t2065 (shares infrastructure; file this task after t2065 lands OR coordinate so both land together)
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | t2065 helper + qlty path-arg behaviour |
| Implementation | 2h | Workflow + helper subcommand + docs |
| Testing | 1h | Throwaway PRs for pass/fail/bypass cases |
| **Total** | **~3.5h** | |
