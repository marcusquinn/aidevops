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

## Counter Safety (grep -c)

**`grep -c` outputs its count to stdout AND exits 1 when there are zero matches.** The widespread idiom below therefore appends `echo`'s output to grep's own `0`, producing a multi-line string `"0\n0"` on the zero-match path:

```bash
# BANNED — produces "0\n0" when pattern is absent
count=$(grep -c 'pat' file 2>/dev/null || echo "0")
```

Canonical failure modes:

- Output corruption when interpolated into text (parent #20402 rendered `Progress: **0\n0 done, 0\n0 remaining**`)
- Broken numeric comparisons — `[[ "$count" -eq 0 ]]` raises a runtime error under `set -e` on non-integer strings
- Broken arithmetic — `$((count + 1))` is a syntax error
- Silent plural/singular bugs — `printf '%d files\n' "$count"` prints only the first integer

### Allowed pattern — `safe_grep_count` (preferred)

Scripts that source `shared-constants.sh` should use the helper:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

count=$(safe_grep_count 'pat' file)
count=$(printf '%s\n' "$data" | safe_grep_count 'needle')
count=$(safe_grep_count -E '^[a-z]+$' file)
```

All `grep` flags pass through (`-E`, `-i`, `-F`, etc.). The helper always prints a single integer on a single line, including when the file does not exist or the pattern has zero matches.

### Allowed pattern — inline fallback

YAML workflow steps, bootstrap scripts, and standalone CLIs that cannot source `shared-constants.sh` use the inline form:

```bash
count=$(grep -c 'pat' file 2>/dev/null || true)
[[ "$count" =~ ^[0-9]+$ ]] || count=0
```

`|| true` catches grep's zero-match exit 1; the regex guard collapses any unexpected output (multi-line, empty, non-numeric) to `0`.

### Enforcement

- CI gate: `.github/workflows/counter-stack-check.yml` (diff-scoped — scans only PR-changed `.sh` / `.yml` files).
- Local check: `.agents/scripts/counter-stack-check.sh --scan-all`.
- Remediation snippets: `.agents/scripts/counter-stack-check.sh --fix-hint`.

**Test fixtures** that must contain the anti-pattern as a literal (e.g. `counter-stack-check.sh` itself, test files that verify the gate fires) add this directive in the first 20 lines:

```bash
# counter-stack-check:disable
```

The scanner skips any file with that directive.

### Originating incident

- PR [#20573](https://github.com/marcusquinn/aidevops/pull/20573) — Fix A for `.github/workflows/issue-sync.yml` phase-nudge visible corruption
- Parent issue #20581 (t2762) — systemic sweep and prevention
- Canonical reference implementation: `.agents/scripts/progressive-load-check.sh:80-97` (pre-existing correct counter usage)

## Code-generators and the string-literal ratchet (t2834)

The string-literal ratchet (`pre-commit-hook.sh::validate_string_literals`) flags any `"..."`-quoted substring of 4+ chars that appears 3+ times in a single file, with the ratchet baselined at zero for **new** files (existing files are grandfathered at HEAD). Helpers that emit SVG, HTML, XML, or any other attribute-rich markup trip this trivially because every element repeats `width="`, `height="`, `fill="`, etc. as boundary fragments.

### Banned pattern — inline attribute fragments

Multiple `printf` calls (or one heredoc with many elements) each containing inline `attr="value"` fragments:

```bash
# Trips the ratchet — `" fill="`, `" width="`, `" height="` count >= 3
printf '  <rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>\n' "$x" "$y" "$w" "$h" "$c"
printf '  <text x="%s" y="%s" font-family="%s" fill="%s">%s</text>\n' "$x" "$y" "$f" "$c" "$t"
```

### Allowed pattern — attribute-builder helpers

Build attribute strings via a single `'%s="%s" '` format template, eliminating inline fragments entirely:

```bash
_ATTR_FMT='%s="%s" '

_svg_attrs() {
    local _out=""
    while [[ $# -ge 2 ]]; do
        local _k="$1" _v="$2"
        # shellcheck disable=SC2059  # _ATTR_FMT is a trusted constant
        _out+=$(printf "$_ATTR_FMT" "$_k" "$_v")
        shift 2
    done
    printf '%s' "${_out%% }"
    return 0
}

_svg_elem() {
    local _tag="$1"; shift
    local _attrs; _attrs=$(_svg_attrs "$@")
    printf '  <%s %s/>\n' "$_tag" "$_attrs"
    return 0
}

# Usage — no inline attr= fragments, no ratchet trip
_svg_elem rect x "$x" y "$y" width "$w" height "$h" fill "$c"
```

Canonical implementation: `.agents/scripts/loc-badge-helper.sh::_svg_attrs / _svg_elem / _svg_open / _svg_close / _svg_text_elem`.

### Ratchet baseline-at-zero for new files

Every ratchet-style validator (string-literal, positional-parameter, function-complexity, nesting-depth, file-size) compares HEAD content vs staged content. For an **existing** file with pre-existing violations, the ratchet only blocks when the staged count exceeds HEAD — pre-existing debt is grandfathered.

For a **new** file, HEAD count is zero. Every violation is "new" and blocks the commit.

**Practical rule:** in a new file, follow the strict pattern from line 1. The "fix later" approach available to maintenance commits on legacy files is not available to new files.

Examples of strict patterns required from line 1 of every new shell helper:

- Positional parameters: `local _arg="$1"` always (never bare `case "$1" in` or `VAR="$2"`)
- Function arguments: `local _msg="$1"` at the top of every function body
- Repeated string fragments: extract to constants OR build via a helper template (see attribute-builder pattern above)

### Detection

Reproduce the validator locally before committing a new helper:

```bash
# Show literals that would trigger the ratchet (after the canonical sed pre-strip)
grep -v '^[[:space:]]*#' your-helper.sh | sed -E '
  s/"\$[A-Za-z_][A-Za-z0-9_]*"//g
  s/"\$\{[^}]*\}"//g
  s/"\$@"//g
  s/"\$[0-9*#?$!-]"//g
' | grep -oE '"[^"]{4,}"' | grep -vE '^"[0-9]+\.?[0-9]*"$' | grep -vE '^"\$' | sort | uniq -c | awk '$1 >= 3' | sort -rn

# Show direct positional-parameter usage that would trigger
awk '
  { line = $0
    gsub(/\047[^\047]*\047/, "", line)
    if (line ~ /^[[:space:]]*#/) next
    sub(/[[:space:]]+#.*/, "", line)
    if (line ~ /local[[:space:]].*=.*\$[1-9]/) next
    if (line ~ /\$[1-9]/) print NR ": " $0
  }
' your-helper.sh
```

Both must be empty before commit.

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
