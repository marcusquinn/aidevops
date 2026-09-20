# GH#32100: Reduce aidevops CLI function complexity

## Files Scope

- EDIT: `aidevops.sh`
- EDIT: `.agents/scripts/tests/test-aidevops-update-transaction.sh`

## Integration scope recovery

`cmd_update()` was decomposed into private helpers to reduce its complexity below
the enforced threshold. The transaction test extracts and sources `cmd_update()`
alone, so it must source the extracted helper functions before invoking the CLI
fixture. This is a reversible test-fixture change within the existing outcome.

## Verification

- `bash .agents/scripts/tests/test-aidevops-update-transaction.sh`
- `bash -n aidevops.sh`
- `shellcheck aidevops.sh`
- `.agents/scripts/complexity-regression-helper.sh check --base origin/main --head HEAD`
