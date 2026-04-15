<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shell Helper Style Guide

Canonical rules for `.agents/scripts/**/*.sh`: **source `shared-constants.sh` OR use `[[ -z "${VAR+x}" ]]` guards**. Never declare `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, or `NC` at top level without a guard. Never `readonly` those names outside `shared-constants.sh`.

Enforcement: `shell-init-pattern-check.sh` + CI (Phase 2, t2053). Rule: `prompts/build.txt` → Quality Standards.

## Why this guide exists

On 2026-04-09, `init-routines-helper.sh:22` re-assigned `GREEN` after `shared-constants.sh` had declared it `readonly`. Under `set -Eeuo pipefail`, this fatally aborted `setup.sh`, silently skipping privacy/canonical guards. **Auto-update was broken for 4 days** (GH#18702, GH#18693). PR #18728 patched that script; this guide + t2053 roadmap prevent recurrence. Audit (2026-04-15): **18 scripts** with unguarded plain-assignment + **2 production scripts** with the worse `readonly` form — all latent repeats.

## Canonical shared variables

`shared-constants.sh` is the single source of truth:

| Variable | Purpose |
|----------|---------|
| `COLOR_RED`, `…GREEN`, `…YELLOW`, `…BLUE`, `…PURPLE`, `…CYAN`, `…WHITE`, `COLOR_RESET` | Canonical names (preferred in new code) |
| `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, `NC` | Short aliases (still supported) |

All are `readonly`. Re-assignment in a sourced child aborts under `set -Eeuo pipefail`. Colors not in `shared-constants.sh` (`MAGENTA`, `GRAY`, `BOLD`, `DIM`) are safe to declare locally — still follow Pattern B for consistency. Add new canonical colors to `shared-constants.sh` in a separate PR.

## The three allowed patterns

### Pattern A — Preferred: source `shared-constants.sh`

For scripts inside `.agents/scripts/` with a predictable path to `shared-constants.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
```

Then use `${RED}`, `${GREEN}`, etc. directly — stays in sync automatically. For subdirectories: `source "${SCRIPT_DIR}/../shared-constants.sh"`.

### Pattern B — Fallback: granular `${VAR+x}` guard

For scripts that must run without `shared-constants.sh` — early bootstrap, standalone CLIs, `bash <(curl …)`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'
```

`${VAR+x}` distinguishes *unset* from *set-to-empty* — parent's `readonly` wins; standalone picks up fallback. **Do not use `${VAR:-}`** — it treats set-to-empty as unset and overwrites in edge cases.

### Pattern C — Private internal: prefixed names

For test harnesses where colors must never leak to callers. Prefix must be `TEST_`, `_<script_name>_`, or documented in `shared-constants.sh`:

```bash
readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'
```

Safe because names don't collide with the canonical set. `readonly` is fine here. **Not for production helpers** — prefer Pattern A/B in non-test scripts.

## Banned patterns

The lint gate (Phase 2) rejects these:

### Banned: unguarded plain assignment

```bash
# BAD — collides with readonly from shared-constants.sh
RED='\033[0;31m'
GREEN='\033[0;32m'
```

Fix: Pattern A or B.

### Banned: unguarded `readonly` on canonical names

```bash
# WORST — breaks on re-sourcing even without shared-constants
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
```

Most dangerous: sourcing twice from any parent (common in test harnesses / nested `source` chains) triggers immediate abort. Fix: Pattern B (production) or Pattern C (private/test).

### Discouraged: coarse include-guard

```bash
if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'
fi
```

All-or-nothing: if parent set some colors manually without the sentinel, child skips fallback → partially undefined under `set -u`. Pattern B handles each variable independently — strictly safer. Existing code may remain; migrate opportunistically.

## Migration checklist

1. Identify current pattern (plain, readonly, include-guard, prefixed).
2. Choose target: A (stable path to `shared-constants.sh`), B (standalone bootstrap), C (test harness only).
3. Remove unguarded assignments; add new block after `set -Eeuo pipefail`, before function definitions.
4. Verify standalone (`bash ./script.sh --help`) AND sourced entry point (`setup.sh --non-interactive` / pulse).
5. `shellcheck` clean → commit.

Phase 2 lint gate (`shell-init-pattern-check.sh`) automates detection and PR verification.

## Audit data (2026-04-15)

529 scripts scanned, 337 source `shared-constants.sh`:

| Pattern | Count | Safety | Fix |
|---------|-------|--------|-----|
| Unguarded plain | 18 | **BROKEN** w/ parent `readonly` | A or B |
| Unguarded `readonly` on canonical names | 13 | **WORST** — breaks on re-sourcing | B (prod) / C (test) |
| Granular `${VAR+x}` guard | 24 | Safe (Pattern B) | — |
| Include guard | 6 | Safe but coarse | migrate opportunistically |
| Prefixed vars | 50 | Safe (Pattern C) | normalise in Phase 7 |

Of the 13 unguarded-readonly: 2 production (`sonarcloud-autofix.sh`, `coderabbit-cli.sh`), 11 test harnesses (inconsistent — bare `RED` instead of `TEST_RED`).

## Phased migration roadmap (t2053)

| Phase | Scope | Key files |
|-------|-------|-----------|
| 1 | Foundation (this file) | style guide + `build.txt` rule + `architecture.md` |
| 2 | Lint gate (MUST land before 3) | `shell-init-pattern-check.sh` + CI + unit test |
| 3 | Tier 1+2 (setup-chain) | `install-hooks.sh`, `doctor-helper.sh`, `pre-edit-check.sh`, `setup/_routines.sh` |
| 4 | Tier 3 (pulse/worker) | `stuck-detection-helper.sh`, `opus-review-helper.sh`, `security-audit-sweep.sh` |
| 5 | Tier 4 (standalone) | `design-preview-helper.sh`, `colormind-helper.sh`, `tabby-helper.sh` |
| 6 | Banned `readonly` elimination | `sonarcloud-autofix.sh`, `coderabbit-cli.sh` + test harness Pattern C normalisation |
| 7 | Prefixed-var normalisation (opt.) | consolidate `C_`, `LC_`, `TEST_` conventions |
| 8 | Other shared-var categories (opt.) | `SCRIPT_DIR`, `REPO_ROOT`, `set -E` consistency |

Each phase = own child task + PR (≤5 files per PR, t1422 cap).

## Related

- **Originating incident**: PR #18728, GH#18702 (primary), GH#18693 (cascade victim)
- **Parent task**: GH#18735 (t2053)
- **Canonical source**: `.agents/scripts/shared-constants.sh` (lines ~354–374)
- **Prior art using Pattern B**: `watercrawl-helper.sh:58`, `security-helper.sh:22`, `routine-log-helper.sh:30`
- **Prior art using Pattern A (include guard variant)**: `circuit-breaker-helper.sh:64-70`
- **Build-time rule**: `prompts/build.txt` → "Quality Standards"
- **Architecture pointer**: `aidevops/architecture.md` → "Shell Helper Initialization"
