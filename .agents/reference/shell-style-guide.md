<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shell Helper Style Guide

Canonical rules for `.agents/scripts/**/*.sh`: **source `shared-constants.sh` OR use `[[ -z "${VAR+x}" ]]` guards**. Never declare `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, or `NC` at top level without a guard. Never `readonly` those names outside `shared-constants.sh`.

Enforcement: `shell-init-pattern-check.sh` + CI workflow (Phase 2 of t2053). Rule in `prompts/build.txt` → Quality Standards.

## Allowed patterns

### Pattern A — Preferred: source `shared-constants.sh`

For scripts inside `.agents/scripts/` with a stable path to `shared-constants.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

echo -e "${GREEN}[OK]${NC} sourced shared constants"
```

Use `${RED}`, `${GREEN}`, etc. directly — no local declarations needed. Subdirectory scripts: `source "${SCRIPT_DIR}/../shared-constants.sh"`.

### Pattern B — Fallback: granular `${VAR+x}` guard

For scripts runnable without `shared-constants.sh` (early bootstrap, standalone CLIs, `bash <(curl …)` distribution):

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

`${VAR+x}` distinguishes *unset* from *set-to-empty* — parent with `shared-constants.sh` wins; standalone picks up fallback. **Do not use `${VAR:-}`** — it treats set-to-empty as unset.

### Pattern C — Private internal: prefixed names

For test harnesses and strictly-internal utilities only. Prefix must be `TEST_`, `_<script_name>_`, or documented in `shared-constants.sh`:

```bash
readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'
```

`readonly` is safe here — prefixed names don't collide with canonical set. **Do not use Pattern C in production helpers** — inconsistent naming forces readers to translate between `TEST_RED` and `RED`.

## Banned patterns

The lint gate (Phase 2) rejects these:

**Unguarded plain assignment** — collides with `readonly` from `shared-constants.sh`:

```bash
# BAD
RED='\033[0;31m'
```

Fix: Pattern A or B.

**Unguarded `readonly` on canonical names** — breaks on re-sourcing even without `shared-constants.sh`:

```bash
# WORST
readonly RED='\033[0;31m'
```

Fix: Pattern B (production) or Pattern C with prefix (tests).

**Coarse include-guard** (discouraged, allowed for backward compat):

```bash
if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
fi
```

Problem: all-or-nothing — if parent set *some* colors without the sentinel, child skips fallback and colors are partially undefined under `set -u`. Pattern B handles each variable independently. Existing include-guard code may remain; migrate opportunistically.

## Canonical shared variables

`shared-constants.sh` declares (all `readonly`):

| Variable | Purpose |
|----------|---------|
| `COLOR_RED`, `COLOR_GREEN`, `COLOR_YELLOW`, `COLOR_BLUE`, `COLOR_PURPLE`, `COLOR_CYAN`, `COLOR_WHITE`, `COLOR_RESET` | Canonical `COLOR_*` names (preferred in new code) |
| `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, `NC` | Short-name aliases (still supported) |

Colors not in `shared-constants.sh` (e.g., `MAGENTA`, `GRAY`, `BOLD`, `DIM`) are safe to declare locally but should follow Pattern B for consistency. New canonical colors → add to `shared-constants.sh` in a separate PR first.

## Migration checklist

When converting a helper to Pattern A or B:

1. Identify current pattern (plain, readonly, include-guard, or prefixed).
2. Choose target — A (inside `.agents/scripts/`, stable path), B (standalone bootstrap), C (test harness only).
3. Replace unguarded assignments with chosen pattern block (after `set -Eeuo pipefail`, before functions).
4. Test standalone (`bash ./the-script.sh --help`) and sourced (`setup.sh --non-interactive` or pulse). `shellcheck` must pass.
5. Commit. Phase 2 lint gate (`shell-init-pattern-check.sh`) automates detection and PR enforcement.

## Why this guide exists

On 2026-04-09, `init-routines-helper.sh:22` assigned `GREEN='\033[0;32m'` at top level. `setup.sh` sources it after `shared-constants.sh` (which has `readonly GREEN`). Under `set -Eeuo pipefail`, the re-assignment fatally aborted `setup.sh`, silently skipping `setup_privacy_guard` and `setup_canonical_guard`. **Auto-update was broken for 4 days** (GH#18702, cascade: GH#18693). PR #18728 patched that script; this guide prevents recurrence.

Audit (2026-04-15): **18 scripts** with unguarded plain assignments and **2 production scripts** (`sonarcloud-autofix.sh`, `coderabbit-cli.sh`) using `readonly` — all latent repeats of the same outage.

## Audit data (2026-04-15)

529 files scanned, 337 source `shared-constants.sh`:

| Pattern | Count | Safety | Fix |
|---------|-------|--------|-----|
| Unguarded plain (`GREEN='…'`) | 18 | **BROKEN** when parent has `readonly` | A or B |
| Unguarded `readonly` on canonical names | 13 | **WORST** — breaks on re-sourcing | B (prod) or C (tests) |
| Granular guard (`[[ -z "${VAR+x}" ]] && VAR='…'`) | 24 | Safe (Pattern B) | — |
| Include guard (`if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]`) | 6 | Safe but coarse | migrate |
| Prefixed vars (`TEST_RED`, `C_GREEN`) | 50 | Safe (Pattern C) | normalise Phase 7 |

Of the 13 unguarded-readonly: 2 production (`sonarcloud-autofix.sh`, `coderabbit-cli.sh`), 11 test harnesses.

## Phased migration roadmap (t2053)

Each phase ships as its own child task/PR (≤5 files per PR, t1422 quality-debt cap):

1. **Phase 1** — Foundation: this guide + `prompts/build.txt` rule + `architecture.md` cross-ref.
2. **Phase 2** — Lint gate: `shell-init-pattern-check.sh` + CI + unit test. Must land before Phase 3.
3. **Phase 3** — Tier 1+2 (setup-chain): `install-hooks.sh`, `install-hooks-helper.sh`, `doctor-helper.sh`, `pre-edit-check.sh`, `setup/_routines.sh`.
4. **Phase 4** — Tier 3 (pulse/worker): `stuck-detection-helper.sh`, `opus-review-helper.sh`, `secret-hygiene-helper.sh`, `security-audit-sweep.sh`, `deploy-agents-on-merge.sh`.
5. **Phase 5** — Tier 4 (standalone): `design-preview-helper.sh`, `colormind-helper.sh`, `contest-helper.sh`, `tabby-helper.sh`, `ssh-key-audit-helper.sh`.
6. **Phase 6** — Eliminate banned `readonly`: `sonarcloud-autofix.sh`, `coderabbit-cli.sh`, `agent-sources-helper.sh` + test harness prefix normalisation. Final: zero violations.
7. **Phase 7** — Prefixed-var normalisation (optional): consolidate `C_`, `LC_`, `TEST_` conventions.
8. **Phase 8** — Extend to other shared-variable categories (optional): `SCRIPT_DIR`, `REPO_ROOT`, `set -E`, error-print helpers.

## Related

- **Originating incident**: PR #18728, GH#18702 (primary), GH#18693 (cascade)
- **Parent task**: GH#18735 (t2053)
- **Canonical source**: `.agents/scripts/shared-constants.sh`
- **Prior art**: Pattern B: `watercrawl-helper.sh:58`, `security-helper.sh:22`, `routine-log-helper.sh:30`. Pattern A (include guard): `circuit-breaker-helper.sh:64-70`.
- **Build-time rule**: `prompts/build.txt` → "Quality Standards"
- **Architecture pointer**: `aidevops/architecture.md` → "Shell Helper Initialization"
