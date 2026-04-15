<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shell Helper Style Guide

Canonical rules for shell scripts under `.agents/scripts/**/*.sh`. Short version: **source `shared-constants.sh` OR use `[[ -z "${VAR+x}" ]]` guards**. Never declare `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, or `NC` at top level without a guard. Never `readonly` those names outside `shared-constants.sh`.

Enforcement: `shell-init-pattern-check.sh` + CI workflow (Phase 2 of t2053). Rule in `prompts/build.txt` → Quality Standards.

## Why this guide exists

On 2026-04-09, `init-routines-helper.sh:22` assigned `GREEN='\033[0;32m'` at top level. `setup.sh` sources it after `shared-constants.sh`, which had already declared `readonly GREEN`. Under `set -Eeuo pipefail`, the re-assignment fatally aborted `setup.sh`, silently skipping `setup_privacy_guard` and `setup_canonical_guard`. **Auto-update was broken for 4 days** until a maintainer traced the cascade. Workers dispatched against unrelated issues (GH#18693, GH#18702) died mid-run and escalated to `needs-maintainer-review` before anyone noticed the root cause.

PR #18728 patched that one script. This style guide and the t2053 migration roadmap exist to prevent the next instance. An audit of `.agents/scripts/` (2026-04-15) found **18 scripts** with the same unguarded plain-assignment shape and **2 production scripts** (`sonarcloud-autofix.sh`, `coderabbit-cli.sh`) using the worse `readonly` form. Every one of those is a latent repeat of the same outage, waiting for a source order to cross.

## Canonical shared variables

`shared-constants.sh` is the single source of truth. It declares:

| Variable | Purpose |
|----------|---------|
| `COLOR_RED`, `COLOR_GREEN`, `COLOR_YELLOW`, `COLOR_BLUE`, `COLOR_PURPLE`, `COLOR_CYAN`, `COLOR_WHITE`, `COLOR_RESET` | Canonical `COLOR_*` names (preferred in new code) |
| `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, `NC` | Short-name aliases (still supported) |

All of the above are declared `readonly`. Any subsequent top-level re-assignment in a sourced child script will abort under `set -Eeuo pipefail`.

Colors **not** declared in `shared-constants.sh` (e.g., `MAGENTA`, `GRAY`, `BOLD`, `DIM`) are safe to declare locally but should still follow Pattern B to stay consistent. If you find yourself wanting a new canonical color, add it to `shared-constants.sh` in a separate PR before using it.

## The three allowed patterns

### Pattern A — Preferred: source `shared-constants.sh`

Use for any script inside `.agents/scripts/` that can rely on a predictable path to `shared-constants.sh`.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

echo -e "${GREEN}[OK]${NC} sourced shared constants"
```

Then use `${RED}`, `${GREEN}`, etc. directly. No local declarations needed. This is the **preferred** pattern because it keeps every helper in sync with the canonical definitions automatically.

**When the script lives in a subdirectory** (`.agents/scripts/setup/_common.sh`, `.agents/scripts/tests/test-foo.sh`), adjust the path: `source "${SCRIPT_DIR}/../shared-constants.sh"`.

### Pattern B — Fallback: granular `${VAR+x}` guard

Use when the script must be runnable **without** `shared-constants.sh` on PATH — early bootstrap of `setup.sh`, standalone CLIs distributed outside the framework, or scripts that are often invoked via `bash <(curl …)`.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# Fallback colors — only assigned if not already set by a parent.
# Safe whether this script is exec'd standalone, sourced from a parent
# that has already sourced shared-constants.sh, or sourced twice.
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'
```

The `${VAR+x}` test distinguishes *unset* from *set-to-empty*, so the fallback assigns only if no parent has declared the variable. A parent that has already sourced `shared-constants.sh` wins; a standalone run picks up the fallback. Either way, no collision.

**Do not use plain `${VAR:-}`** — that treats set-to-empty as unset and will overwrite an intentional empty string in edge cases. Use `${VAR+x}` specifically.

### Pattern C — Private internal: prefixed names

Use for test harnesses and strictly-internal utilities where the colors must never leak to sourcing callers. Prefix is mandatory and must be one of: `TEST_`, `_<script_name>_`, or a prefix documented in `shared-constants.sh` itself.

```bash
# Test-only colors — prefixed to avoid any collision with shared-constants.
readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'
```

Pattern C is safe because the variables don't share names with the canonical set. `readonly` is allowed here (and encouraged) because the scope is private and self-contained.

**When NOT to use Pattern C**: in production helpers. Prefixed names make the codebase inconsistent and force readers to mentally translate between `TEST_RED` and `RED`. Prefer Pattern A/B in any script that isn't a test harness.

## Banned patterns

The lint gate (Phase 2) will reject any of these:

### Banned: unguarded plain assignment

```bash
# BAD — collides with readonly RED from shared-constants.sh
RED='\033[0;31m'
GREEN='\033[0;32m'
```

Remediation: switch to Pattern A (source shared-constants.sh) or Pattern B (add `[[ -z "${VAR+x}" ]] &&` guard to each line).

### Banned: unguarded `readonly` on canonical names

```bash
# WORST — fails even on simple re-sourcing, not just after shared-constants
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
```

This is the most dangerous pattern because the script breaks itself: sourcing it twice from any parent (common in test harnesses and in nested `source` chains) triggers an immediate abort. Remediation: switch to Pattern B for production scripts, or Pattern C with a prefixed name for private ones.

### Discouraged: coarse include-guard

```bash
# Kept for backward compat but discouraged in new code.
if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    # … all colors or none
fi
```

Why discouraged: the include guard is all-or-nothing. If the parent has sourced `shared-constants.sh` (setting `_SHARED_CONSTANTS_LOADED=1`), *none* of the colors get assigned in the child — which is usually fine. But if the parent has set *some* colors manually without setting the sentinel, the child skips its fallback and the colors are partially undefined, which fails under `set -u`. Pattern B is strictly safer because it handles each variable independently.

Existing include-guard code is allowed to remain but should migrate to Pattern A or B opportunistically.

## Migration checklist

When converting a helper to Pattern A or B:

1. Identify the current pattern (plain, readonly, include-guard, or prefixed).
2. Choose the target pattern — A if the script is inside `.agents/scripts/` and has a stable path to `shared-constants.sh`, B if it must bootstrap standalone, C only if it's a test harness.
3. Remove the unguarded assignments.
4. Add the new block near the top of the script, after `set -Eeuo pipefail` and before any function definitions.
5. Run the script standalone (`bash ./the-script.sh --help`) to confirm it still works without being sourced from `setup.sh`.
6. Run it via its normal entry point (e.g., `setup.sh --non-interactive`, or the pulse) to confirm the sourced path still works.
7. `shellcheck` must still be clean.
8. Commit.

The Phase 2 lint gate (`shell-init-pattern-check.sh`) automates steps 1 and 8 for the PR.

## Audit data (2026-04-15)

Scan of `.agents/scripts/**/*.sh` (529 files, 337 source `shared-constants.sh`):

| Pattern | Count | Safety | Remediation |
|---------|-------|--------|-------------|
| Unguarded plain (`GREEN='\033[0;32m'`) | 18 | **BROKEN** when parent has `readonly`; coincidentally OK when sourced once | Pattern A or B |
| Unguarded `readonly` on canonical names | 13 | **WORST** — breaks on simple re-sourcing even without shared-constants | Pattern B (production) or C (tests) |
| Granular guard (`[[ -z "${VAR+x}" ]] && VAR='…'`) | 24 | Safe — already follows Pattern B | no action |
| Include guard (`if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]`) | 6 | Safe but coarse | migrate opportunistically |
| Prefixed vars (`TEST_RED`, `C_GREEN`, `LC_GREEN`) | 50 | Safe — follows Pattern C | normalise prefix in Phase 7 |

Among the 13 unguarded-readonly scripts, only 2 are production helpers (`sonarcloud-autofix.sh`, `coderabbit-cli.sh`) — the remaining 11 are test harnesses where the private-scope safety net catches the issue, but the style is still inconsistent with Pattern C (bare `RED` instead of `TEST_RED`).

## Phased migration roadmap (t2053)

- **Phase 1 — Foundation (this file)**: style guide + `prompts/build.txt` rule + `architecture.md` cross-reference.
- **Phase 2 — Lint gate**: `shell-init-pattern-check.sh` + CI workflow + unit test. MUST land before Phase 3 so migrations can be auto-verified.
- **Phase 3 — Migrate Tier 1+2** (setup-chain adjacent): `install-hooks.sh`, `install-hooks-helper.sh`, `doctor-helper.sh`, `pre-edit-check.sh`, `setup/_routines.sh`.
- **Phase 4 — Migrate Tier 3** (pulse/worker adjacent): `stuck-detection-helper.sh`, `opus-review-helper.sh`, `secret-hygiene-helper.sh`, `security-audit-sweep.sh`, `deploy-agents-on-merge.sh`.
- **Phase 5 — Migrate Tier 4** (standalone tools): `design-preview-helper.sh`, `colormind-helper.sh`, `contest-helper.sh`, `tabby-helper.sh`, `ssh-key-audit-helper.sh`.
- **Phase 6 — Eliminate banned `readonly` triplet**: `sonarcloud-autofix.sh`, `coderabbit-cli.sh`, `agent-sources-helper.sh`, plus test harnesses → Pattern C prefix normalisation. Final audit: `shell-init-pattern-check.sh --scan-all` must report zero violations.
- **Phase 7 — Prefixed-var normalisation** (optional): consolidate `C_`, `LC_`, `TEST_` conventions where they drift.
- **Phase 8 — Extend to other shared-variable categories** (optional): `SCRIPT_DIR`, `REPO_ROOT`, `set -E` consistency, shared error-print helpers.

Each phase ships as its own child task and PR, respecting the t1422 quality-debt cap of ≤5 files per PR.

## Related

- **Originating incident**: PR #18728, GH#18702 (primary), GH#18693 (cascade victim)
- **Parent task**: GH#18735 (t2053)
- **Canonical source**: `.agents/scripts/shared-constants.sh` (lines ~354–374)
- **Prior art using Pattern B**: `watercrawl-helper.sh:58`, `security-helper.sh:22`, `routine-log-helper.sh:30`
- **Prior art using Pattern A (include guard variant)**: `circuit-breaker-helper.sh:64-70`
- **Build-time rule**: `prompts/build.txt` → "Quality Standards"
- **Architecture pointer**: `aidevops/architecture.md` → "Shell Helper Initialization"
