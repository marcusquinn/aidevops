<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2223: Post-merge brief AC verification fails on Ubuntu for macOS-specific briefs

## Origin

- **Created:** 2026-04-18
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** Surfaced during t2201 post-merge CI review. PR #19707 merged despite the "Verify Brief Acceptance Criteria" check failing, because the maintainer gate does not block on this check. Investigation showed both failing AC blocks were platform-flakes, not real bugs:
  - **Block 2:** `/opt/homebrew/bin/bash -c '...'` → `exit 127: No such file or directory` (Ubuntu runner has no Homebrew).
  - **Block 4:** `bash .agents/scripts/tests/test-bash-reexec-guard.sh 2>&1 | grep -q 'env-var leak'` — on Ubuntu `/bin/bash` is already bash 5+, so the test's Test 15a/15b SKIP the env-var-leak assertions ("no modern bash available" fall-through). The "env-var leak" PASS string never appears in output, grep returns 1.

## What

The `Verify Brief Acceptance Criteria` workflow should either:
1. Run on a runner that can satisfy the brief's AC (macOS runner when the brief references macOS-only paths), OR
2. Declare platform requirements in the brief (a simple front-matter or header convention) so the workflow picks the right runner, OR
3. Fail gracefully with a platform-specific warning instead of a hard failure when the brief targets a platform the runner doesn't match.

After this task:

1. A brief can declare target platforms (options: `macos`, `linux`, `any`, `all` — where `all` requires a matrix).
2. `.github/workflows/verify-brief-acceptance-criteria.yml` reads the declaration and runs on the appropriate runner (or matrix).
3. The t2201 brief (retroactively) either moves to `macos` targeting or is rewritten to use platform-neutral paths (`$(command -v bash)` instead of hard-coded `/opt/homebrew/bin/bash`).
4. When a brief uses a path that is not available on the selected runner, the workflow emits a clear diagnostic instead of exit-127 noise.

## Why

- **False signal.** The current behaviour trains maintainers to ignore this check. Issues bypass merge because the check fails on every macOS-specific brief. Over time the check becomes decorative and real AC failures get missed.
- **Brief author friction.** Authors writing mechanically-correct briefs for macOS-specific fixes (like t2201) have no way to make the check pass. Their choice is: (a) write platform-neutral ACs even when the bug is macOS-specific, which reduces precision, or (b) accept the failure, which normalises noise.
- **Runner cost asymmetry.** GitHub macOS runners are more expensive. A matrix-everywhere default is wasteful; platform declaration is the right resolution.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 1 workflow file + 1 brief template file + possibly `todo/tasks/t2201-brief.md` (retroactive fix).
- [x] **Every target file under 500 lines?**
- [ ] **Exact `oldString`/`newString` for every edit?** — Workflow file needs design (matrix runners, platform selector logic). Not mechanical.
- [ ] **No judgment or design decisions?** — Yes there are: whether to use matrix, declarative platform tag, or runner selector; whether to retrofit existing briefs or just new ones.
- [x] **No error handling or fallback logic to design?** — Actually some: what happens if the brief declares a platform the workflow can't provide?
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?** — Probably 1-2h.
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:standard`

**Tier rationale:** Requires modest design judgment (platform declaration convention + matrix-vs-selector decision). Not mechanical enough for `tier:simple`. Not architecturally deep enough for `tier:thinking`.

## PR Conventions

Leaf task — use `Resolves #19721` when the issue is created.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/verify-brief-acceptance-criteria.yml` — read a platform declaration from the brief (e.g. a `Platform: macos|linux|any|all` line or YAML front-matter); select the runner accordingly; matrix-run when `all`. Non-matching runner → skip gracefully with a clear status message, not a failure.
- `EDIT: .agents/templates/brief-template.md` — add a `## Platform` section with documented values and examples.
- **Optional retroactive:** `EDIT: todo/tasks/t2201-brief.md` — add `Platform: macos` OR rewrite its ACs to use `$(command -v bash 2>/dev/null)` instead of hard-coded `/opt/homebrew/bin/bash`. The t2201 brief is historical, so this is cosmetic; the future-facing fix is the workflow + template change.

### Reference Pattern

- `.github/workflows/verify-brief-acceptance-criteria.yml` already has a step that parses the brief — extend it to also parse the platform declaration.
- See `.github/workflows/parent-task-keyword-check.yml` for an example of workflow-level conditional logic based on issue labels (for the style of "read metadata then act" pattern).
- Grep for existing brief files with OS-specific paths to gauge how many would retroactively want `Platform: macos`:
  ```bash
  grep -rl '/opt/homebrew\|launchctl\|gatekeeper\|xcrun' todo/tasks/ 2>/dev/null | wc -l
  ```

### Verification

```bash
# 1. Platform declaration parsed correctly
grep -n 'platform' .github/workflows/verify-brief-acceptance-criteria.yml
# Expect: at least one match referencing a platform/os selector

# 2. Template has the section
grep -q '## Platform' .agents/templates/brief-template.md
echo $?  # expect 0

# 3. For a macOS-tagged brief, the workflow picks a macos runner; for linux-tagged,
#    picks ubuntu; for 'all', runs a matrix. Verify via workflow-lint / act, or by
#    filing a test brief and pushing a PR.
```

## Acceptance Criteria

Platform: linux

- [ ] Workflow `.github/workflows/verify-brief-acceptance-criteria.yml` reads a platform declaration from the brief (either a single-line `Platform: <os>` header or a `## Platform` section value).

  ```yaml
  verify:
    method: bash
    run: "grep -q 'platform' .github/workflows/verify-brief-acceptance-criteria.yml && grep -qi 'runs-on' .github/workflows/verify-brief-acceptance-criteria.yml"
  ```

- [ ] Template documents the `Platform` convention with at least `macos`, `linux`, `any`, and `all` as legal values.

  ```yaml
  verify:
    method: bash
    run: "grep -q '## Platform' .agents/templates/brief-template.md && grep -q 'macos' .agents/templates/brief-template.md && grep -q 'linux' .agents/templates/brief-template.md"
  ```

- [ ] When a brief declares `Platform: macos` and the workflow is dispatched on a PR that modifies that brief, the AC step runs on a `macos-latest` runner (or equivalent). When it declares `Platform: linux`, it runs on `ubuntu-latest`. When it declares `Platform: all`, a matrix runs both.

  ```yaml
  verify:
    method: visual-or-actlint
    note: "Verify via GitHub Actions simulator or by pushing a test PR with each platform tag and confirming the runner labels in the workflow run log."
  ```

- [ ] t2201 retroactive: the t2201 brief's ACs either declare `Platform: macos` or are rewritten to use `$(command -v bash 2>/dev/null)` instead of `/opt/homebrew/bin/bash`.

  ```yaml
  verify:
    method: bash
    run: "grep -qE 'Platform: macos|command -v bash' todo/tasks/t2201-brief.md"
  ```

## Context & Decisions

- **Why not just skip the check on failure instead of failing it?** Because a skipped check still counts as "green" in most merge gates and doesn't teach the author anything. A platform-aware workflow is the right fix; a global skip hides real AC failures too.
- **Why not matrix everywhere by default?** GitHub's macOS runners are 10x the cost of Linux. Defaulting to matrix would multiply CI spend for small gain — most briefs are platform-neutral.
- **Why declarative platform tag instead of auto-detection of macOS-specific paths in the AC?** Auto-detection is brittle (globs of known-macOS paths drift). A single-line declaration is a few bytes in the brief and makes intent explicit.
- **Related to `SYNC_PAT`:** The workflow also hit `GraphQL: Resource not accessible by integration (addComment)` when trying to post results to the PR. Already documented in AGENTS.md (t2029/t2048/t2166) — out of scope for this task; filed separately.

## Relevant Files

- `.github/workflows/verify-brief-acceptance-criteria.yml` — primary file.
- `.agents/templates/brief-template.md` — template must document the convention.
- `todo/tasks/t2201-brief.md` — canonical example of a brief that failed the check; useful as a test case.
- `AGENTS.md` — may warrant a one-line note about the `Platform` convention in the "Briefs, Tiers, and Dispatchability" section.

## Dependencies

- **Blocked by:** none.
- **Blocks:** any future macOS-specific brief will continue to hit the same CI flake until this lands.
- **Related:** t2201 (surfacing bug), t2029/t2048/t2166 (`SYNC_PAT` permission on the comment-posting step — separate issue).

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Design | 15m | Choose matrix-vs-selector strategy; decide header format. |
| Implementation | 30m | Workflow edit + template edit + t2201 retroactive. |
| Testing | 30m | Push test PR with each platform tag; verify runner selection in run logs. |
| **Total** | **~75m** | tier:standard. |
