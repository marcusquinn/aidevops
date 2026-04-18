# Shell Test Harness Templates

Templates for writing bash test harnesses that test aidevops framework helpers.
Encode lessons from t2189 (PR #19682) — two silent-failure pitfalls that each
cost ~20 min of `bash -x` debugging during that session.

## Usage

```bash
cp .agents/scripts/tests/templates/test-harness-template.sh \
   .agents/scripts/tests/test-<feature>.sh
# Edit the copy — replace placeholder comments and example test functions
shellcheck .agents/scripts/tests/test-<feature>.sh
```

## Pitfalls Encoded

### Pitfall 1 — `set -e` kills before `$?` is readable

**Symptom:** Test harness exits silently with no FAIL output. All PASS results
disappear too. The harness "passes" by not running.

**Root cause:** `set -euo pipefail` causes bash to exit the moment any command
returns non-zero. When a helper under test is designed to return 1 on certain
inputs (e.g. a gate function, a staleness detector), `set -e` kills the script
immediately — before the `local rc=$?` capture line executes.

**Fix:** Use `set -uo pipefail` (drop the `-e`) and capture `$?` explicitly:

```bash
# Wrong — set -e kills here if my_helper returns 1:
set -euo pipefail
my_helper "arg"          # script exits
local rc=$?              # never reached

# Right — capture is safe without set -e:
set -uo pipefail
my_helper "arg"
local rc=$?              # captured in all cases
[[ "$rc" -eq 1 ]]        # assertion runs
```

See the comment block at the top of `test-harness-template.sh` for the full
explanation embedded in the file so future authors see it without needing to
read this README.

### Pitfall 2 — `local` outside a function silently drops the assignment

**Symptom:** A counter variable is always 0 or empty even after assignment.
`bash -x` shows the assignment running but the value never sticks.

**Root cause:** In bash 5.x, `local var=value` at the top-level scope (outside
any function) silently succeeds with exit code 0 but **does not assign the
value**. This is a no-op that produces no error and no warning.

**Fix:** Use plain assignments at the script's top level; reserve `local` for
use inside function bodies only:

```bash
# Wrong — silently dropped under bash 5.x when outside a function:
local TESTS_RUN=0
local TESTS_FAILED=0

# Right — plain top-level assignment:
TESTS_RUN=0
TESTS_FAILED=0
```

Inside functions, `local` is correct and required per shellcheck:

```bash
print_result() {
    local test_name="$1"   # correct inside a function
    local passed="$2"
    ...
}
```

## Mock CLI Stub Pattern

When the helper under test shells out to `gh`, `git`, or another CLI:

1. Put the stub in `tests/fixtures/mock-<feature>.sh` (separate file so
   `setup_test_env` stays under the 100-line complexity threshold).
2. `setup_test_env()` prepends a `$TEST_ROOT/bin/` to `PATH` and copies the
   stub there under the target binary name (e.g. `gh`).
3. Drive scenarios via plain text state files in `$TEST_ROOT`. The stub reads
   these to produce canned responses; tests mutate them between assertions.

See `tests/fixtures/mock-gh-interactive-handover.sh` for a complete working
example from PR #19682.

## RC-Capture Pattern (mandatory)

Every test function that calls a helper which may return non-zero must capture
`$?` in a dedicated statement immediately after the call:

```bash
test_A_my_case() {
    my_helper "arg"
    local rc=$?          # capture first, nothing between call and capture
    if [[ "$rc" -eq 1 ]]; then
        print_result "A: my case" 0
    else
        print_result "A: my case" 1 "Expected 1, got $rc"
    fi
    return 0
}
```

**Do not** use `if my_helper "arg"; then` — under `pipefail`, `if`-condition
invocations suppress the exit code and the pattern defeats its own purpose.

## Reference

- `test-pulse-merge-interactive-handover.sh` — full working example (10 tests)
- `fixtures/mock-gh-interactive-handover.sh` — full working mock stub
- PR #19682 — origin of these lessons (t2189 session)
- GH#19684 (t2197) — this template
