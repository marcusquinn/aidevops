<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shell Helper Style Guide

Canonical rules for `.agents/scripts/**/*.sh`: **source `shared-constants.sh` OR use `[[ -z "${VAR+x}" ]]` guards**. Never assign `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, or `NC` at top level without a guard. Never `readonly` those names outside `shared-constants.sh`. Enforcement: `shell-init-pattern-check.sh` + CI. See `prompts/build.txt` → "Quality Standards".

**Incident rationale (GH#18702):** On 2026-04-09, `init-routines-helper.sh:22` had an unguarded `GREEN='\033[0;32m'`. `setup.sh` sources it after `shared-constants.sh` (which has `readonly GREEN`). Under `set -Eeuo pipefail`, the re-assignment fatally aborted `setup.sh`, silently skipping `setup_privacy_guard` and `setup_canonical_guard` — **auto-update broken for 4 days** (cascade: GH#18693, fixed: PR #18728).

## Banned patterns

**Unguarded plain assignment** (collides with parent `readonly`) → fix: Pattern A or B.

```bash
# BAD
RED='\033[0;31m'
```

**Unguarded `readonly` on canonical names** (breaks on re-sourcing) → fix: Pattern B (production), C with prefix (tests).

```bash
# WORST
readonly RED='\033[0;31m'
```

**Coarse include-guard** (allowed for backward compat; discouraged):

```bash
if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
fi
```

All-or-nothing: colors partially undefined under `set -u` when parent set some without the sentinel. Pattern B handles each independently. Migrate opportunistically.

## Allowed patterns

### A — source `shared-constants.sh` (preferred)

Inside `.agents/scripts/` with stable path to `shared-constants.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

echo -e "${GREEN}[OK]${NC} sourced shared constants"
```

Use `${RED}`, `${GREEN}`, etc. directly. Subdirectory scripts: `source "${SCRIPT_DIR}/../shared-constants.sh"`.

### B — granular `${VAR+x}` guard (fallback)

Scripts without `shared-constants.sh` (early bootstrap, standalone CLIs, curl-distributed):

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# Fallback colors — only assigned if not already set by a parent.
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'
```

`${VAR+x}` distinguishes *unset* from *set-to-empty* — parent `shared-constants.sh` wins; standalone picks up fallback. **Do not use `${VAR:-}`** — it treats set-to-empty as unset.

### C — prefixed names (test harnesses and strictly-internal utilities only)

Prefix must be `TEST_`, `_<script_name>_`, or documented in `shared-constants.sh`:

```bash
readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'
```

`readonly` safe — prefixed names don't collide. **Production helpers: use Pattern A or B.**

## Canonical shared variables

`shared-constants.sh` declares (all `readonly`):

| Variable | Purpose |
|----------|---------|
| `COLOR_RED`, `COLOR_GREEN`, `COLOR_YELLOW`, `COLOR_BLUE`, `COLOR_PURPLE`, `COLOR_CYAN`, `COLOR_WHITE`, `COLOR_RESET` | Canonical `COLOR_*` names (preferred in new code) |
| `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, `NC` | Short-name aliases (still supported) |

Non-canonical colors (`MAGENTA`, `GRAY`, `BOLD`, `DIM`) → declare locally with Pattern B. New canonicals → add to `shared-constants.sh` first.

## Migration checklist

1. Identify current pattern (plain, readonly, include-guard, or prefixed).
2. Choose target — A (inside `.agents/scripts/`, stable path), B (standalone bootstrap), C (test harness only).
3. Replace unguarded assignments with chosen pattern block (after `set -Eeuo pipefail`, before functions).
4. Test standalone (`bash ./the-script.sh --help`) and sourced (`setup.sh --non-interactive`). `shellcheck` must pass.
5. Commit. The lint gate (`shell-init-pattern-check.sh`) automates detection and PR enforcement.

## Related

- **Originating incident**: PR #18728, GH#18702 (primary), GH#18693 (cascade)
- **Consolidation parent**: GH#18735 (t2053, closed — all phases complete as of PR #19180)
- **Canonical source**: `.agents/scripts/shared-constants.sh`
- **Prior art**: Pattern B: `watercrawl-helper.sh:58`, `security-helper.sh:22`, `routine-log-helper.sh:30`. Include-guard: `circuit-breaker-helper.sh:64-70`.
- **Build-time rule**: `prompts/build.txt` → "Quality Standards"
- **Architecture pointer**: `aidevops/architecture.md` → "Shell Helper Initialization"
