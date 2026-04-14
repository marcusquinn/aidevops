<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2065: CI regression gate — block PRs that increase total qlty smell count

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** Diagnosis showed the repo has 109 qlty smells and nothing in CI prevents new smells from landing. The simplification ratchet only measures shell line counts, not qlty smells, so Python/JS/TS/mjs files have accumulated debt unchecked. This is the missing enforcement.

## What

Add a GitHub Actions workflow `.github/workflows/qlty-regression.yml` that runs `qlty smells --all --sarif` against (a) the PR merge-base and (b) the PR head, compares the total smell count, and **fails the check when the PR introduces a net increase in smells**. The workflow is a required check on all PRs touching non-doc files.

The gate includes:

- **Per-rule breakdown** in the PR comment so the author sees exactly which rules regressed
- **Per-file breakdown** showing which files added new smells
- **Allowlist override** via a `ratchet-bump` label, documented in the workflow, for cases where a smell increase is justified (mirrors existing shell complexity ratchet model)
- **Docs-only PR bypass** — if the PR touches only `*.md`, `todo/**`, `.github/**` (non-workflow), `README*`, skip the scan
- **SARIF artifact upload** for each PR so maintainers can inspect the full delta

## Why

- **Today there is no mechanism to prevent smell regressions.** The framework's `code-quality.yml` workflow only checks shell `FUNCTION_COMPLEXITY_THRESHOLD` / `FILE_SIZE_THRESHOLD` / `NESTING_DEPTH_THRESHOLD` — none of which cover Python, JS/TS/mjs, or cyclomatic complexity. A PR adding a new 200-line Python script with cyclomatic 40 passes every gate.
- **The current simplification ratchet only removes smells.** Without a regression gate, new work reintroduces smells as fast as simplification removes them. The sweep reports "1121 closed / 0 open" while the actual smell count sits at 109 — the metric and the reality are decoupled.
- **This gate is the foundation for "stay at A".** Without it, any C→A progress regresses within weeks of new feature work.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify? No — new workflow + helper script + docs
- [ ] Complete code blocks for every edit? No — needs design judgment
- [ ] No judgment or design decisions? No — must decide merge-base strategy, label override, exemption rules

**Selected tier:** `tier:thinking`

**Tier rationale:** Designing a CI regression gate requires decisions about merge-base computation (GitHub Actions `pull_request` event gives shallow clones), SARIF diffing strategy (count-based vs fingerprint-based), and override labels. Non-trivial design with correctness implications.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Current smell baseline:
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq '.runs[0].results | length'
# Expected: ~109 at time of filing.

# 2. Existing code-quality workflow to model on:
ls .github/workflows/code-quality.yml
cat .github/workflows/code-quality.yml

# 3. Qlty CLI install pattern already used in CI (search for qlty in existing workflows):
rg "qlty" .github/workflows/
```

### Files to Modify

- `NEW: .github/workflows/qlty-regression.yml` — the regression gate workflow
- `NEW: .agents/scripts/qlty-regression-helper.sh` — the diff logic (SARIF count + per-rule + per-file breakdown, markdown comment generator)
- `EDIT: .github/workflows/code-quality.yml` — optionally add cross-reference comment pointing to the new gate (no functional change)
- `EDIT: .agents/AGENTS.md` — document the gate and the `ratchet-bump` override label (1 short paragraph under "Code Quality" / "Regression Gates")
- `EDIT: .agents/configs/complexity-thresholds.conf` — add `QLTY_SMELL_THRESHOLD=<current-count>` (initial baseline)

### Implementation Steps

1. **Workflow structure.** Triggers: `pull_request` on `opened`, `synchronize`, `reopened`. Permissions: `pull-requests: write`, `contents: read`. Jobs:
   - `detect-scope` — checks if PR touches any non-doc file; sets an output `should_scan=true|false`
   - `qlty-diff` — runs only if `should_scan=true`. Checks out with `fetch-depth: 0` to get merge-base. Installs qlty via the same method as `code-quality.yml`. Runs qlty on merge-base commit + HEAD commit, diffs via `qlty-regression-helper.sh`, posts PR comment, sets exit code.

2. **`qlty-regression-helper.sh` behaviour.** Accepts `--base <sha> --head <sha> --repo <path>`. Checks out each commit to a temp dir, runs `qlty smells --all --sarif --no-snippets --quiet`, parses both SARIF outputs with jq:
   - Total count delta
   - Per-rule delta (new smells grouped by `ruleId`)
   - Per-file delta (top 10 files with new smells)
   - Outputs a markdown report for the PR comment and exits 1 if delta > 0 AND no `ratchet-bump` label present.

3. **Override mechanism.** `ratchet-bump` label on the PR allows the gate to pass with warning. Matches existing shell ratchet pattern (bump with documented reason).

4. **Initial baseline.** Seed `QLTY_SMELL_THRESHOLD` in `complexity-thresholds.conf` with the current count. The gate doesn't actually *use* this value (it uses base-vs-head diff), but it anchors the ratchet so t2067 (the ratchet-down task) has a starting point.

5. **Docs-only bypass.** If every changed file in the PR matches `^(\.github/.*\.md|docs/|README|\.md$|todo/|TODO\.md)`, skip qlty entirely and pass the check with `skipped (docs-only)`.

### Verification

```bash
# Workflow lints clean
actionlint .github/workflows/qlty-regression.yml

# Helper script lints clean
shellcheck .agents/scripts/qlty-regression-helper.sh

# Dry-run the helper against a known commit pair
.agents/scripts/qlty-regression-helper.sh --base HEAD~5 --head HEAD --dry-run

# Smoke test: open a throwaway PR that deliberately adds a smell, confirm the gate fails
```

## Acceptance Criteria

- [ ] New workflow `.github/workflows/qlty-regression.yml` exists and triggers on `pull_request`
  ```yaml
  verify:
    method: bash
    run: "test -f .github/workflows/qlty-regression.yml && actionlint .github/workflows/qlty-regression.yml"
  ```
- [ ] Helper `.agents/scripts/qlty-regression-helper.sh` exists, is executable, passes shellcheck
  ```yaml
  verify:
    method: bash
    run: "test -x .agents/scripts/qlty-regression-helper.sh && shellcheck .agents/scripts/qlty-regression-helper.sh"
  ```
- [ ] `complexity-thresholds.conf` contains `QLTY_SMELL_THRESHOLD=<N>` with `N` equal to the merge-base smell count at landing time
  ```yaml
  verify:
    method: codebase
    pattern: "^QLTY_SMELL_THRESHOLD=[0-9]+"
    path: ".agents/configs/complexity-thresholds.conf"
  ```
- [ ] Workflow is added to branch protection as a required check (manual step, document in PR)
- [ ] A PR that deliberately adds a smell fails the check; a PR with `ratchet-bump` label passes with warning
- [ ] Docs-only PRs (changing only `*.md`) skip the scan and pass immediately
- [ ] AGENTS.md updated to describe the gate and override label

## Context & Decisions

- **Why total-count diff, not SARIF fingerprint diff?** Fingerprint diff is more precise but qlty's fingerprinting is not stable across line shifts. Count diff is simple and correct for "net new smells".
- **Why per-file breakdown in the comment?** The existing shell ratchet's failure messages don't surface *which file* regressed; authors have to run qlty locally to find out. Front-loading the data in the PR comment saves a round-trip.
- **Why not block on every PR?** Docs-only PRs shouldn't pay the scan cost (qlty on a large repo takes ~30s). The scope gate keeps CI fast for doc contributors.

## Relevant Files

- `.github/workflows/code-quality.yml` — existing shell complexity workflow (model the runner setup, qlty install, PR comment pattern)
- `.agents/configs/complexity-thresholds.conf` — where the baseline lands
- `.agents/scripts/stats-functions.sh:1829` — `_sweep_qlty` already invokes qlty the right way; model the flags there

## Dependencies

- **Blocked by:** none — can ship immediately
- **Blocks:** t2067 (ratchet-down discipline depends on this gate existing)
- **External:** none — qlty CLI is already used in CI

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Existing code-quality.yml, qlty flags, SARIF schema |
| Implementation | 3h | Workflow + helper script + docs |
| Testing | 1h | Throwaway PR to verify both pass and fail cases |
| **Total** | **~4.5h** | |
