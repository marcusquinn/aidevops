## What

Make the four line-count assertions in `.agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh` compare counts numerically (`-eq`), so `test_decision_policy_decide`, `test_decision_policy_escalate` and `test_decision_policy_races` pass on macOS as well as Linux.

## Why

BSD `wc -l` pads its count (`'       2'`). The assertions used string equality (`[[ "$(wc -l <file)" == 2 ]]`), which is false on macOS. On unmodified main (c506de537e), `test-pr-checkpoint-continuation-helper.sh` reported `3 / 214 tests failed`, all three `test_decision_policy_*`. An xtrace of `test_decision_policy_decide` ended at the line-count assertion with `[[        2 == 2 ]]` then `return 1`. GH#38365 fixed the fixture timestamps but not this padding. Local macOS runs therefore showed false failures that hide real regressions.

## How

- `.agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh`: replace `== N` with `-eq N` in the `wc -l` comparisons of the decision-policy tests. Other suites already strip padding with `tr -d ' '`, or use `-eq`, as at line 336 of the same file.
- No production code changes.

### Files Scope

- .agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh
- TODO.md
- todo/tasks/t19040-brief.md

## Acceptance

- `bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh` reports 0 failures on macOS.
- ShellCheck clean.

## Verification

`bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh` (macOS): exit 0, all four `test_decision_policy_*` PASS. `shellcheck .agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh`: clean.
