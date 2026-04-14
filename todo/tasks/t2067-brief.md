<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2067: Add `QLTY_SMELL_THRESHOLD` to ratchet — extend the ratchet discipline to smell count

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** The repo's ratchet (`.agents/configs/complexity-thresholds.conf`) tracks `FUNCTION_COMPLEXITY_THRESHOLD`, `NESTING_DEPTH_THRESHOLD`, `FILE_SIZE_THRESHOLD`, `BASH32_COMPAT_THRESHOLD` — all shell-only, all measured as violation counts. None of them cover Python, JS/TS/mjs, or cyclomatic complexity. Meanwhile qlty reports 109 smells in exactly those languages. The ratchet has nothing to bite against.

## What

Extend the existing ratchet mechanism to include `QLTY_SMELL_THRESHOLD` as a first-class ratchet counter, with the same "buffer of 2, ratchet down on every PR that reduces it" discipline as the shell counters:

1. Add `QLTY_SMELL_THRESHOLD=<current-count-plus-2-buffer>` to `.agents/configs/complexity-thresholds.conf`
2. Wire the ratchet check into `.github/workflows/code-quality.yml` — the check runs `qlty smells --all` on the PR HEAD, counts total smells, fails if `count > QLTY_SMELL_THRESHOLD`
3. Add an auto-ratcheting step: when a PR merges to main AND brings the count below `threshold - 2`, automatically bump `QLTY_SMELL_THRESHOLD` down to `new_count + 2` in a follow-up commit on main (model on the existing shell ratchet post-merge logic if present, or a new small workflow)
4. Document the ratchet discipline in `.agents/configs/complexity-thresholds-history.md` with initial entry

This is **complementary to t2065** (the PR regression gate). The regression gate enforces "no net increase *in this PR*". This ratchet enforces "the total count is and remains bounded" and ratchets down over time.

## Why

- Without a hard threshold, even `t2065`'s regression gate can drift: a PR that reduces count by 3 followed by a PR that adds 3 nets zero — and on the regression gate this is fine, but the long-term trajectory is flat. A ratchet that tracks the *minimum count ever achieved* forces monotonic improvement.
- The existing shell ratchet is the proven model. It took `FUNCTION_COMPLEXITY_THRESHOLD` from 404 → 30 over months. Replicating the pattern for smells unlocks the same asymptote-toward-zero dynamic.
- Multi-language coverage: this is the first counter that covers non-shell files, closing the gap that let mjs/ts/py files accumulate debt.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Requires touching the CI workflow, understanding how the existing ratchet post-merge auto-commit works (or designing one if it doesn't), and getting the initial baseline right. Design-heavy.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`. **Depends on t2065** — the helper script from t2065 produces the count this task checks against.

## How (Approach)

### Files to Modify

- `EDIT: .agents/configs/complexity-thresholds.conf` — add `QLTY_SMELL_THRESHOLD=<N+2>`
- `EDIT: .agents/configs/complexity-thresholds-history.md` — document the new counter with initial entry
- `EDIT: .github/workflows/code-quality.yml` — add the smell count check as a new job step
- `NEW or EDIT: .github/workflows/ratchet-post-merge.yml` — post-merge auto-ratchet (if this workflow doesn't exist, create it; if similar shell-ratchet logic exists, extend it)
- `EDIT: .agents/AGENTS.md` — one sentence under "Code Quality / Ratchets" pointing at the new counter

### Implementation Steps

1. **Snapshot the baseline.** At time of filing, local SARIF reports 109 smells. Use `qlty smells --all --sarif --no-snippets --quiet | jq '.runs[0].results | length'` at the PR's merge base to compute the current count. Initial threshold = `count + 2` (matching existing shell ratchet convention).

2. **Wire the check into `code-quality.yml`.** Add a job `qlty-smell-threshold`:
   - `runs-on: ubuntu-latest`
   - Install qlty (same method as existing steps)
   - `count=$(~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet | jq '.runs[0].results | length')`
   - `threshold=$(grep '^QLTY_SMELL_THRESHOLD=' .agents/configs/complexity-thresholds.conf | cut -d= -f2)`
   - Fail if `count > threshold`. On failure, print per-rule and per-file breakdown.

3. **Post-merge auto-ratchet.** Triggers on `push` to `main` if the diff touches `.agents/configs/complexity-thresholds.conf` or any source file that could have changed the smell count. Compute new count, if `new_count + 2 < current_threshold`, write the new threshold and commit with a generated message like `chore: ratchet QLTY_SMELL_THRESHOLD N→M (-M_DELTA)`. This requires the same branch-protection bypass as the existing TODO-sync push (reference `t2048/SYNC_PAT`).

4. **Bootstrap edge case.** First PR that adds this counter will run the check against itself — make sure the initial threshold is `current_count + 2` so the check passes.

5. **History entry.** Add to `complexity-thresholds-history.md` documenting the baseline and rationale.

### Verification

```bash
# Config parses
grep -E '^QLTY_SMELL_THRESHOLD=[0-9]+' .agents/configs/complexity-thresholds.conf

# Workflow lints
actionlint .github/workflows/code-quality.yml

# The check passes on current main
count=$(~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet | jq '.runs[0].results | length')
threshold=$(grep '^QLTY_SMELL_THRESHOLD=' .agents/configs/complexity-thresholds.conf | cut -d= -f2)
test "$count" -le "$threshold"
```

## Acceptance Criteria

- [ ] `complexity-thresholds.conf` contains `QLTY_SMELL_THRESHOLD=<N>` where `N = (initial_count + 2)`
  ```yaml
  verify:
    method: codebase
    pattern: "^QLTY_SMELL_THRESHOLD=[0-9]+"
    path: ".agents/configs/complexity-thresholds.conf"
  ```
- [ ] `code-quality.yml` has a new job step that reads `QLTY_SMELL_THRESHOLD` and fails if current count exceeds it
- [ ] Post-merge workflow auto-ratchets when the count drops (either a new workflow or extension of existing ratchet logic)
- [ ] `complexity-thresholds-history.md` has an entry for the new counter with rationale
- [ ] `actionlint .github/workflows/*.yml` passes

## Context & Decisions

- **Why buffer of 2?** Matches the existing shell ratchet convention exactly. Absorbs small fluctuations from formatting/metadata changes without triggering a ratchet-down on every no-op PR.
- **Why a separate post-merge workflow instead of rolling into `code-quality.yml`?** `code-quality.yml` runs on PRs and shouldn't write to main. Post-merge logic that commits to main needs its own trigger and its own auth (SYNC_PAT per t2048).
- **Depends on t2065** — the PR regression gate. They're complementary: t2065 is per-PR delta, t2067 is absolute threshold with monotonic decay. Both are needed for "get to A and stay there".

## Relevant Files

- `.agents/configs/complexity-thresholds.conf` — existing ratchet format
- `.agents/configs/complexity-thresholds-history.md` — existing history format
- `.github/workflows/code-quality.yml` — existing ratchet check
- `.agents/scripts/complexity-scan-helper.sh` — the helper that reads thresholds (model edit on lines 833, 835)

## Dependencies

- **Blocked by:** t2065 (the PR regression gate should land first so there are two layers; this task can progress in parallel and merge after)
- **Blocks:** none
- **External:** post-merge auto-commit needs `SYNC_PAT` (already on the backlog as t2048)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Existing ratchet workflow + SYNC_PAT status |
| Implementation | 2h | Config + workflow + post-merge logic |
| Testing | 1h | Smoke test on a throwaway PR |
| **Total** | **~3.5h** | |
