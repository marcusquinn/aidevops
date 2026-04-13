<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2053 — Consolidate shell helper initialization pattern (parent)

**Session origin**: interactive, Claude Code (claude-opus-4-6), follow-up to PR #18728 (GH#18702/18693).

**Type**: parent-task (roadmap). This issue will NEVER be implemented directly — only its children will. Protected by `parent-task` label and `_is_protected_label()` guard in `issue-sync-helper.sh`.

## Why

PR #18728 fixed one catastrophic instance of a systemic problem: `init-routines-helper.sh:22` collided with `readonly GREEN` from `shared-constants.sh`, killed `setup.sh` under `set -Eeuo pipefail`, broke auto-update for **4 days** (2026-04-09 to 2026-04-13), and cascaded into workers silently dying on GH#18693 and GH#18702 until both escalated to `needs-maintainer-review`.

The fix in PR #18728 patched the one helper in the direct sourcing chain. **It did not address the other 14 unguarded scripts with the same bug shape**, the **3 scripts using the much-worse unguarded `readonly` pattern**, or the **50+ scripts using inconsistent-but-safe prefix conventions**. The framework has five different patterns in active use for the same concern, and no enforcement to stop drift.

This is a parent task to consolidate all of this into **one canonical pattern**, migrate every helper to it, enforce it with a lint gate in CI, and document it as the authoritative style rule so future development doesn't regress.

**Cost of not doing this**: the next readonly collision will kill auto-update again for an unknown number of days. The cascade is almost invisible until a maintainer notices `needs-maintainer-review` piling up. PR #18728 took ~45 min of interactive investigation to trace — the fix itself was 5 lines. Preventing the next one is worth the migration effort.

## Current state (audit data, 2026-04-13)

Scan of `.agents/scripts/**/*.sh` (529 files total):

| Pattern | Count | Safety | Example |
|---|---|---|---|
| Unguarded plain (`GREEN='\033[0;32m'`) | **15** | **BROKEN** when parent has readonly; sources OK once | `design-preview-helper.sh`, `pre-edit-check.sh`, `doctor-helper.sh` |
| Unguarded `readonly` (`readonly RED='\033[0;31m'`) | **3** | **WORST** — breaks even on simple re-sourcing | `sonarcloud-autofix.sh`, `coderabbit-cli.sh`, `shared-constants.sh` (protected by include guard) |
| Granular guard (`[[ -z "${VAR+x}" ]] && VAR='...'`) | 24 | **SAFE** | `watercrawl-helper.sh`, `security-helper.sh`, `routine-log-helper.sh` |
| Include guard (`if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then ...`) | 6 | Safe but coarse (all or nothing) | `circuit-breaker-helper.sh` |
| Prefixed vars (`TEST_GREEN`, `C_GREEN`, `LC_GREEN`) | 50 | Safe but inconsistent naming | `verify-run-helper.sh`, `list-verify-helper.sh`, `test-*.sh` |

**Sources-shared-constants count**: 337 scripts (63% of all helpers). Any of those 337 that also contains an unguarded color assign is a time-bomb — the 18 identified above are the known ones, but the scan pattern is conservative. A thorough migration should also check for uncommon color names (`GRAY`, `MAGENTA`, `BOLD`, etc.).

### Setup-chain criticality

The 18 unguarded scripts break down by proximity to the setup.sh sourcing chain:

- **Tier 0 (killed auto-update)**: `init-routines-helper.sh` — already fixed in PR #18728.
- **Tier 1 (directly sourced by `setup.sh`)**: `setup/_common.sh` — fixed defensively in PR #18728. Other setup/_*.sh modules: currently safe because they source `_common.sh` first, but structurally identical to the bug.
- **Tier 2 (invoked by setup-chain scripts as child processes)**: `install-hooks.sh`, `install-hooks-helper.sh`, `doctor-helper.sh`, `pre-edit-check.sh`. These run in fresh shells so the readonly doesn't propagate — but any future change that sources them instead of exec'ing them would regress.
- **Tier 3 (invoked by pulse/worker lifecycle)**: `stuck-detection-helper.sh`, `opus-review-helper.sh`, `secret-hygiene-helper.sh`, `security-audit-sweep.sh`, `deploy-agents-on-merge.sh`. Same child-process safety net, same regression risk.
- **Tier 4 (standalone tools)**: `design-preview-helper.sh`, `colormind-helper.sh`, `contest-helper.sh`, `tabby-helper.sh`, `ssh-key-audit-helper.sh`, `agent-sources-helper.sh`. Rarely sourced; lowest risk today but most inconsistent with the rest of the framework.

## Canonical design pattern (proposal)

Every shell script in `.agents/scripts/**/*.sh` MUST follow exactly one of these three patterns for shared-variable initialization. No exceptions outside of `shared-constants.sh` itself (which is the source of truth).

### Pattern A — Prefer: source `shared-constants.sh`

```bash
# shellcheck source=shared-constants.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
```

Then use `${RED}`, `${GREEN}`, etc. directly. This is the **preferred** pattern for any script that lives inside `.agents/scripts/` and has a reliable path to shared-constants.

### Pattern B — Fallback: granular guard

```bash
# Fallback colors — only assigned if not already set by a parent.
# Safe whether this script is exec'd standalone, sourced from a parent
# that has already sourced shared-constants.sh, or sourced twice.
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'
```

Use Pattern B for scripts that need to be runnable without shared-constants on PATH (e.g., the very early bootstrap of `setup.sh`, or standalone CLIs distributed outside the framework).

### Pattern C — Private internal: prefixed names

```bash
# Test-only or strictly internal colors — prefixed to avoid any collision.
readonly _MYSCRIPT_RED=$'\033[0;31m'
readonly _MYSCRIPT_GREEN=$'\033[0;32m'
```

Use Pattern C only for test harnesses (`test-*.sh`) and strictly-internal utilities where the colors must not leak to sourcing callers. Prefix MUST be `TEST_`, `_<script_name>_`, or documented in the shared-constants header.

### Banned patterns

- `RED='\033[0;31m'` at top level (unguarded plain) — **forbidden**.
- `readonly RED='\033[0;31m'` at top level outside `shared-constants.sh` — **forbidden**.
- `if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then ... fi` — **discouraged** (kept for backward compat in existing files, but new code uses Pattern A or B). The include-guard approach is coarse: it can only set/not-set all colors, no granular fallback.

## Phased implementation plan

This is a parent roadmap. Each phase ships as its own child task and PR, respecting the **t1422 quality-debt cap of ≤5 files per PR**. Children inherit the `parent-task` issue's auto-dispatch tag but **children are normal leaf tasks**, not parents.

### Phase 1 — Foundation (t2053.1)

**Goal**: document the canonical pattern and add it to the style guide.

**Deliverables**:

- `.agents/reference/shell-style-guide.md` — new file (or section in existing style guide) documenting Patterns A/B/C with rationale, banned patterns, and the cross-reference to GH#18702/PR #18728 as the motivating incident.
- Update `.agents/aidevops/architecture.md` — add a "Shell helper initialization" section that points to the style guide.
- Update `.agents/prompts/build.txt` "Quality Standards" section — one-line rule: *"Shell helpers MUST source shared-constants.sh OR use `[[ -z "${VAR+x}" ]]` guards for color/constant fallbacks. Unguarded top-level assignments of shared variable names are forbidden. See `reference/shell-style-guide.md`."*

**Files**: 3.  **Acceptance**: style guide exists, build.txt has the rule, architecture.md cross-references it.

### Phase 2 — Lint gate (t2053.2)

**Goal**: CI-enforce the rule so new regressions are impossible.

**Deliverables**:

- New helper: `.agents/scripts/shell-init-pattern-check.sh` — scans any set of `.sh` files for banned patterns. Exits non-zero on finding: (a) unguarded plain `(RED|GREEN|...)=` at top level, (b) unguarded `readonly (RED|GREEN|...)=` at top level outside `shared-constants.sh`, (c) color var declared after `source shared-constants.sh` without a guard. Emits `file:line:pattern` suggestions and a one-line remediation snippet.
- New GitHub Actions workflow: `.github/workflows/shell-init-pattern-check.yml` — runs the helper on PR diffs (only files under `.agents/scripts/**/*.sh`). Fails PR on violation with a comment pointing to the style guide.
- New regression test: `.agents/scripts/tests/test-shell-init-pattern-check.sh` — unit tests for the checker (positive and negative cases).

**Files**: 3.  **Acceptance**: helper + workflow + test all green on main; deliberately-planted violation fails CI.

**Note**: this phase MUST land before Phase 3 so Phase 3 migrations can be auto-verified.

### Phase 3 — Migrate Tier 1+2 (setup-chain adjacent) (t2053.3)

**Goal**: fix every helper one source away from setup.sh.

**Files** (tier 1 and 2, 5 files max per PR):

1. `.agents/scripts/install-hooks.sh`
2. `.agents/scripts/install-hooks-helper.sh`
3. `.agents/scripts/doctor-helper.sh`
4. `.agents/scripts/pre-edit-check.sh`
5. `.agents/scripts/setup/_routines.sh` (already partially fixed in PR #18728, final pass to align with canonical pattern if needed)

**Acceptance**: Phase 2 lint gate passes clean on each file; manual smoke test (`bash -n`, `shellcheck`, run the script once standalone) confirms behaviour unchanged.

### Phase 4 — Migrate Tier 3 (pulse/worker-adjacent) (t2053.4)

**Files** (5):

1. `.agents/scripts/stuck-detection-helper.sh`
2. `.agents/scripts/opus-review-helper.sh`
3. `.agents/scripts/secret-hygiene-helper.sh`
4. `.agents/scripts/security-audit-sweep.sh`
5. `.agents/scripts/deploy-agents-on-merge.sh`

**Acceptance**: same as Phase 3.

### Phase 5 — Migrate Tier 4 (standalone tools) (t2053.5)

**Files** (5):

1. `.agents/scripts/design-preview-helper.sh`
2. `.agents/scripts/colormind-helper.sh`
3. `.agents/scripts/contest-helper.sh`
4. `.agents/scripts/tabby-helper.sh`
5. `.agents/scripts/ssh-key-audit-helper.sh`

**Acceptance**: same as Phase 3.

### Phase 6 — Eliminate the banned `readonly` triplet (t2053.6)

**Files** (3 files, still ≤5):

1. `.agents/scripts/sonarcloud-autofix.sh` — switch to Pattern B.
2. `.agents/scripts/coderabbit-cli.sh` — switch to Pattern B.
3. `.agents/scripts/agent-sources-helper.sh` — switch to Pattern B.

Plus a final audit pass: a second run of `shell-init-pattern-check.sh --scan-all` must report **zero violations** (enforced in CI on main via a nightly workflow).

### Phase 7 — Prefixed-var normalisation (t2053.7)

**Scope**: the 50 scripts currently using `TEST_`, `C_`, `LC_` prefixes. This phase is lower priority and may be split further — it's mostly cosmetic consolidation, not a safety fix.

**Deliverables**:

- Decide whether `C_` (`list-verify-helper.sh`) and `LC_` (`loop-common.sh`) prefixes should standardise on a single convention. Document the decision in the style guide.
- Test harnesses keep the `TEST_` prefix (this is already dominant and well-understood).
- Any normalisation runs as ≤5-file PRs.

### Phase 8 — Extend pattern to other shared-variable categories (t2053.8, optional)

Once colors are clean, survey for other candidates that follow the same shape:

- `SCRIPT_DIR`, `REPO_ROOT`, `LOGFILE` — sometimes declared readonly, sometimes plain.
- `set -Eeuo pipefail` vs `set -euo pipefail` inconsistency (`-E` traps in functions, useful but not universal).
- Common error-print helpers (`print_error`, `print_info`) — several scripts define their own instead of using shared.

**Not in the critical path**. Spin off only if t2053.1–7 reveal clear enough benefit.

## Dispatch and tier notes

- **Tier for each phase**: `tier:standard` (Sonnet). The pattern is narrative, the files are small, and the migration is mechanical. No phase needs reasoning-tier.
- **Parallelism**: Phases 3, 4, 5 are independent of each other — they can run in parallel once Phase 2 lands. Phases 1→2→(3||4||5||6)→7→8 is the dependency chain.
- **Rollback plan**: each phase is a single small PR, trivially revertable via `git revert`. The canonical pattern is backward-compatible so partial adoption is safe.

## Acceptance criteria (whole parent)

1. `.agents/reference/shell-style-guide.md` (or equivalent) exists and documents Patterns A/B/C.
2. `.agents/prompts/build.txt` Quality Standards section has the one-line enforcement rule.
3. `.agents/scripts/shell-init-pattern-check.sh` helper + CI workflow exist and reject banned patterns.
4. Full scan of `.agents/scripts/**/*.sh` reports **zero unguarded top-level color assignments** and **zero banned `readonly` color declarations outside shared-constants.sh**.
5. All existing helper behaviour preserved (shellcheck clean, tests pass, `setup.sh --non-interactive` runs to `[SETUP_COMPLETE]`).
6. Follow-up audit run (memory-helper.sh search for `setup.sh failed during stale-agent re-deploy`) in `auto-update.log` shows zero new occurrences after Phase 6 merges.

## Related

- **Originating incident**: PR #18728, GH#18702 (primary), GH#18693 (cascade victim)
- **Canonical source**: `.agents/scripts/shared-constants.sh` (lines 312–334 — the readonly declarations that this whole plan exists to coexist with)
- **Prior art using Pattern B**: `.agents/scripts/watercrawl-helper.sh:58`, `.agents/scripts/security-helper.sh:22`, `.agents/scripts/routine-log-helper.sh:30`
- **Prior art using Pattern A (include guard)**: `.agents/scripts/circuit-breaker-helper.sh:64-70` — works but too coarse; new code should use Pattern A+source or Pattern B
