<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Large-File Split Playbook for Shell Libraries

Consolidated from six prior worker attempts on GH#19699, each of which re-discovered
the same framework lessons from scratch. This document exists so the next worker
arrives already knowing the answer.

## 1. When to Use This

Use this playbook when:

- You are responding to a `file-size-debt`, `function-complexity`, or `nesting-depth`
  scanner-filed issue that recommends splitting a shell library.
- You are voluntarily splitting a shell lib that has grown past maintainable size
  (the `file-size` scanner threshold is 1500 lines for `.sh` files).

**Do not use** for non-shell splits (Python, JS, etc.) or for refactors that change
behaviour. This playbook covers mechanical, behaviour-preserving splits only.

## 2. Canonical Pattern

Two in-repo precedents demonstrate the pattern end-to-end:

| Precedent | Orchestrator | Sub-libraries |
|-----------|-------------|---------------|
| Simple | `issue-sync-helper.sh` | `issue-sync-lib.sh` |
| Complex | `headless-runtime-lib.sh` | `headless-runtime-provider.sh`, `headless-runtime-failure.sh`, `headless-runtime-model.sh` |

### 2.1 Orchestrator file

The orchestrator retains the original filename. It keeps:

- The include guard (`[[ -n "${_XXX_LOADED:-}" ]] && return 0`)
- The `shared-constants.sh` import
- The `SCRIPT_DIR` fallback (see 2.3)
- `source` calls to each sub-library
- Any functions whose identity keys must be preserved (see section 3)

### 2.2 Sub-library file

Each sub-library follows this template:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# <Library Name> -- <One-Line Description>
# =============================================================================
# <Multi-line description of what this sub-library covers.>
#
# Usage: source "${SCRIPT_DIR}/<this-file>.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - <any other dependencies>
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_<UNIQUE_NAME>_LIB_LOADED:-}" ]] && return 0
_<UNIQUE_NAME>_LIB_LOADED=1

# --- Functions ---

# <function definitions here>
```

### 2.3 Sourcing sub-libraries from the orchestrator

The orchestrator sources sub-libraries via `$SCRIPT_DIR`. ShellCheck cannot
statically resolve runtime-computed paths, so each source call needs two
directives. From `headless-runtime-lib.sh:102-104`:

```bash
# shellcheck source=./headless-runtime-provider.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-provider.sh"
```

### 2.4 Defensive `SCRIPT_DIR` fallback

Both orchestrators and sub-libraries need `SCRIPT_DIR` to resolve sibling
files. The caller (e.g., `headless-runtime-helper.sh`) usually sets it, but
test harnesses and direct sourcing may not. Add this fallback at the top,
after the include guard. Cite: `issue-sync-lib.sh:35-41`:

```bash
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    # Pure-bash dirname replacement -- avoids external binary dependency
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi
```

## 3. Identity-Key Preservation Rules

The complexity scanners (`complexity-regression-helper.sh`) track violations by
identity keys. Moving code between files can create or destroy violations
depending on the metric.

| Metric | Identity key | Split impact | Action |
|--------|-------------|-------------|--------|
| `function-complexity` | `(file, fname)` | Moving a >100-line function to a new file re-registers it as a **new** violation. | Functions over 100 lines **MUST stay in the original file**. Example: `_run_canary_test` stayed in `headless-runtime-lib.sh` (PR #19821). |
| `file-size` | `(file)` | Splitting automatically resolves the original file's violation. New sub-files are typically under the threshold. | No special action needed. |
| `nesting-depth` | `(file, 'NEST')` | Splitting into new files creates new `(newfile, 'NEST')` keys. With the shfmt-based scanner (t2430), reported depths are accurate per-function measurements, so `+N new` regressions reflect real nesting. | Review each new violation. If real nesting >8 exists, refactor the function. The `complexity-bump-ok` label is available as a last resort. |
| `bash32-compat` | `(construct)` | Splitting is neutral -- the construct identity doesn't include the file. | No special action needed. |

**Critical rule**: before splitting, run `complexity-regression-helper.sh check`
on the pre-split state. Identify every `function-complexity` violation in the
target file. Those functions stay put.

## 4. Known CI False-Positive Classes on Splits

### 4.1 Nesting-depth scanner (t2430 — rewritten)

As of t2430, `scan_dir_nesting_depth` uses a `shfmt --to-json` AST walker
(`scanners/nesting-depth.sh`) that computes accurate per-function nesting
depth. The four false-positive classes from the old AWK scanner are
eliminated by construction:

1. **elif** — AST represents elif as nested IfClause in `.Else`; walker
   treats as same depth (not double-counted).
2. **Prose keywords** — string content is not tokenized as control flow.
3. **`done <<<"$x"`** — WhileClause closes normally regardless of redirect.
4. **Global counter** — FuncDecl nodes provide natural per-function reset.

**Verification**: `headless-runtime-lib.sh` now scores `max_depth=4` (real
max per-function depth), down from the old AWK's `max_depth=83`.

**Implication for file splits**: nesting-depth regressions on file splits
now reflect real nesting. If a split creates `+N new` nesting violations,
the functions genuinely nest >8 levels deep and should be refactored. The
`complexity-bump-ok` override is still available as a last resort but
should rarely be needed for nesting-depth specifically.

**Graceful degradation**: when `shfmt` is unavailable, the scanner falls
back to the legacy AWK with a warning on stderr. The AWK fallback retains
all four false-positive classes — environments without `shfmt` should use
`COMPLEXITY_GUARD_DISABLE=1` for known false positives.

### 4.2 Pre-push complexity guard

The client-side `complexity-regression-pre-push.sh` hook rejects on the same
false positive. Targeted bypass:

```bash
COMPLEXITY_GUARD_DISABLE=1 git push
```

Document this alongside the CI label in your PR body.

## 5. Pre-Commit Hook Gotchas (and Compliant Rewrites)

### 5.1 SC1091 from sourced sub-libraries

The pre-commit ShellCheck hook flags `source "${SCRIPT_DIR}/sub-lib.sh"` as
SC1091 ("Not following: ... was not specified as input"). Fix with an inline
directive and a one-line reason:

```bash
# shellcheck source=./sub-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/sub-lib.sh"
```

### 5.2 Positional parameter validation

`validate_positional_parameters` flags `"$1"` usage in rest-args emit loops.
Compliant rewrite (identical behaviour, no `$1` reference):

```bash
# Before (flagged):
while [[ $# -gt 0 ]]; do printf '%s\0' "$1"; shift; done

# After (compliant):
[[ $# -gt 0 ]] && printf '%s\0' "$@"
```

### 5.3 String-literal validation (t2230 bug)

`validate_string_literals` flags `"$var"` interpolations as "repeated string
literals". These are variable references, not literals -- this is a **known
framework bug** tracked in t2230 (GH#19739).

If you hit this on a split, do NOT rewrite variable references to deduplicate
(that causes code harm). Options:

1. If t2230 has landed, use whatever opt-out it ships.
2. Otherwise: `COMPLEXITY_GUARD_DISABLE=1` + commit with `--no-verify` +
   document the maintainer authorization in the commit message and PR body
   self-assessment section.

## 6. PR Body Template

Copy this skeleton into `gh pr create --body`. Replace placeholders in
`<angle brackets>`.

````markdown
## Summary

Split `<original-file>` (<N> lines) into <M> focused files so every shell
script is under the <threshold>-line file-size-debt threshold. Function groups
move verbatim; no behavioural changes.

| file | lines | scope |
|---|---|---|
| `<orchestrator>` | <N> | thin orchestrator: <scope summary> |
| `<sub-lib-1>` | <N> | <scope summary> |
| `<sub-lib-2>` | <N> | <scope summary> |

Mirrors the `issue-sync-helper.sh` / `issue-sync-lib.sh` split precedent.
Each sub-library has an include guard and a `# shellcheck source=./...`
directive paired with an SC1091 disable (runtime-resolved via `$SCRIPT_DIR`,
cannot be statically followed without `-x`).

## Changes

1. **<M> files** -- <N-1> new sub-libraries + rewritten orchestrator lib. No
   caller-facing API changes; `<caller>` continues to source only
   `<orchestrator>`.
2. **Defensive `SCRIPT_DIR` fallback** in `<orchestrator>` (derived from
   `BASH_SOURCE[0]`, matches the `issue-sync-lib.sh` pattern).
3. **<Any compliant rewrites>** (e.g., rest-arg loops rewritten per
   `reference/large-file-split.md` section 5.2).
4. **`<large-function>` stays in `<orchestrator>`** -- deliberately, to keep
   its `(file, fname)` identity key unchanged so the function-complexity
   metric does not regress.

## Testing

- `shellcheck <all-files>` -- clean at warning+error severity
- Smoke test via the real caller path (`SCRIPT_DIR=... source <orchestrator>`):
  all expected functions resolve; behaviour is identical
- `complexity-regression-helper.sh check` vs `origin/main`:
  - `file-size`: base=<N>, head=<N>, **new=0**
  - `function-complexity`: base=<N>, head=<N>, **new=0**
  - `bash32-compat`: base=<N>, head=<N>, **new=0**
  - `nesting-depth`: base=<N>, head=<N>, new=<K> -- <if K>0, document the functions and their real depth>

## Complexity Bump Justification

> **Note (t2430):** As of t2430, the nesting-depth scanner uses a shfmt AST
> walker that measures real per-function depth. Nesting-depth regressions on
> file splits now reflect genuine nesting. If new=0, delete this section. If
> new>0, document the specific functions and their real depth below.

**`complexity-bump-ok` label applied.** The following functions have nesting
depth >8 and are candidates for refactoring in a follow-up task:

- `<function_name>` in `<file>`: depth=<N> (reason: <brief explanation>)

**Pre-existing depth moved, not introduced:** these functions had the same
nesting depth in the original file. The split relocates them without
changing their structure.

## Related

- Resolves #<issue-number>
- Reference: `reference/large-file-split.md`

## Self-Assessment

**`--no-verify` disclosure:** <if used, document why and what maintainer
authorized it. If not used, delete this section.>
````

## 7. Verification Checklist

Run these checks before pushing:

### 7.1 ShellCheck

```bash
shellcheck .agents/scripts/<orchestrator>.sh .agents/scripts/<sub-lib-1>.sh ...
```

Must be clean at warning+ severity. SC1091 must be suppressed inline (section 5.1),
not globally.

### 7.2 Smoke test

Confirm all expected functions resolve and behaviour is identical:

```bash
SCRIPT_DIR=.agents/scripts source .agents/scripts/<orchestrator>.sh

# Verify key functions are available:
type <function_1> <function_2> <function_3>
```

### 7.3 Complexity regression check

```bash
.agents/scripts/complexity-regression-helper.sh check
```

Expected results for a well-executed split:

- `file-size`: `new=0` (original >threshold file cleared)
- `function-complexity`: `new=0` (large functions stayed in original file)
- `bash32-compat`: `new=0` (splitting is neutral)
- `nesting-depth`: `new>=0` (with the shfmt scanner (t2430), any `new>0` reflects real per-function depth >8; refactor or document per section 4.1)

### 7.4 Pre-push dry run

```bash
COMPLEXITY_GUARD_DISABLE=1 git push --dry-run
```

If the dry run passes with the complexity guard disabled, the only remaining
gate is the CI `complexity-bump-ok` label (section 4.1).

---

## Related

- GH#19699, PR #19821 -- the session that surfaced the missing documentation
- GH#19739 (t2230) -- string-literal hook bug; if fixed, section 5.3 simplifies
- `reference/bash-compat.md` -- Bash 3.2 compatibility rules
- `tools/code-review/code-simplifier.md` -- primary consumer for simplification issues
