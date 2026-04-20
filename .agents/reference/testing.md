<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Testing Conventions

This page documents repo-specific patterns for the shell test suite under
`.agents/scripts/tests/`. It is intentionally short — most tests can be read
top-to-bottom without any framework knowledge.

## The `shared-constants.sh` copy pattern (t2431)

A handful of tests copy `shared-constants.sh` into a temporary directory and
source it from there. This is done so they can also install a stub
`gh-signature-helper.sh` next to the copied file — the wrapper resolves the
helper via `BASH_SOURCE` sibling lookup, so the stub must live in the same
directory as the file being sourced.

**The hard rule:** always copy `shared-constants.sh` via the helper, never
bare.

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PARENT_DIR="${SCRIPT_DIR}/.."

# shellcheck source=./lib/test-helpers.sh
source "${SCRIPT_DIR}/lib/test-helpers.sh"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Stubs go here...

_test_copy_shared_deps "$PARENT_DIR" "$TMPDIR_TEST" || exit 1
_test_source_shared_deps "$TMPDIR_TEST" || exit 1

# Now gh_create_pr, gh_create_issue, _gh_wrapper_auto_sig, etc. are
# defined and the test can assert their behaviour.
```

### Why a helper is mandatory

`shared-constants.sh` is progressively split into sub-libraries — each split
adds a new `source "${_SC_SELF%/*}/<sibling>.sh"` directive at file scope.
Known splits so far:

- PR #20037 (GH#20018) — extracted `gh_*` wrappers into `shared-gh-wrappers.sh`
- PR #20066 (t2427) — extracted feature-toggle loading into `shared-feature-toggles.sh`

Before t2431, tests that copied only `shared-constants.sh` to a tmpdir
silently ran `set -euo pipefail` *after* sourcing, so the non-existent sibling
source printed a warning and the rest of the test executed with the wrappers
undefined — skipping every assertion and exiting 0. Two tests were affected:

- `.agents/scripts/tests/test-gh-wrapper-auto-sig.sh` (30 assertions, 0 running)
- `.agents/scripts/tests/test-comment-wrapper-marker-dedup.sh` (9 assertions, 0 running)

Both tests were "green" in CI the entire time the regression was latent.

The `_test_copy_shared_deps` helper parses `shared-constants.sh` for every
`source "${_SC_SELF%/*}/<file>.sh"` directive and copies each sibling alongside
the orchestrator. When a future split adds a new sibling, the helper picks
it up automatically — no test-file edits required.

### The CI guard

`.github/workflows/test-harness-deps.yml` runs two checks on every relevant
change:

1. **Layer 3** — `.agents/scripts/shared-constants-deps-check.sh` greps for
   any bare `cp ... shared-constants.sh` outside `tests/lib/test-helpers.sh`
   and fails the build on hits. Comment lines that merely *describe* the
   pattern (e.g., "use `_test_copy_shared_deps` rather than a bare
   `cp shared-constants.sh`") are ignored — the check strips inline comments
   before matching.
2. **Layer 4** — the same script verifies that the helper's discovery regex
   still matches the source-directive syntax in `shared-constants.sh`. If a
   future rewrite uses a different syntax (e.g., `. ./sibling.sh` or
   `source "$(dirname ...)/sibling.sh"`) the helper would silently return zero
   deps; the check fails loudly with the candidate lines printed.

The workflow also runs `test-test-helpers.sh` (the helper's own test) and
the two previously-broken tests end-to-end, asserting that each emits at
least one `PASS:` line. A test that runs to completion with zero assertions
is the signature of the original regression class and fails the build.

### Running the check locally

```bash
.agents/scripts/shared-constants-deps-check.sh
bash .agents/scripts/tests/test-test-helpers.sh
bash .agents/scripts/tests/test-gh-wrapper-auto-sig.sh
bash .agents/scripts/tests/test-comment-wrapper-marker-dedup.sh
```

Clean output:

```text
OK: Layer 3: no bare `cp shared-constants.sh` outside helper
OK: Layer 4: parser found N of N sibling source lines
OK: all shared-constants deps checks passed
```

### Adding a new sub-library to shared-constants.sh

1. Add the `source "${_SC_SELF%/*}/<new-sibling>.sh"` directive at file scope
   in `shared-constants.sh`. No test-helper edits required — the parser
   auto-discovers it.
2. Run `.agents/scripts/shared-constants-deps-check.sh` locally — Layer 4
   should show `parser found N+1 of N+1 sibling source lines`.
3. Run `bash .agents/scripts/tests/test-test-helpers.sh` to confirm the
   helper lands every dep (including the new one) in its synthetic tmpdir.

If the new sub-library uses a *different* source syntax (e.g., conditional
loading via `[[ -r ]]`, or a computed path), you must extend
`_test_discover_shared_deps` in `tests/lib/test-helpers.sh` to match the
new pattern — or accept that it won't be copied automatically (which is
fine for conditional deps that tolerate absence).

## Direct-source tests

Most tests under `.agents/scripts/tests/` source `shared-constants.sh`
directly from its real location (`${PARENT_DIR}/shared-constants.sh`). These
tests work unchanged after a split because the siblings live alongside the
orchestrator in the real tree. The copy-and-source pattern is only required
when the test needs to co-locate stubs with the sourced file — typically
for `BASH_SOURCE`-relative helper resolution.

## General conventions

- Each test sets `set -euo pipefail` at the top.
- Each test prints `PASS: <name>` or `FAIL: <name>` per assertion and a final
  `=== Results: X passed, Y failed ===` summary.
- Exit 0 on all-pass, exit 1 on any failure. Exit 0 with zero `PASS:` lines is
  caught by the t2431 CI guard.
- Clean up tmpdirs via `trap 'rm -rf "$TMPDIR_TEST"' EXIT`.
- Stub PATH commands (e.g., `gh`) by prepending a per-test `stub-bin`
  directory to `PATH` in the test, not by globally shadowing them.
