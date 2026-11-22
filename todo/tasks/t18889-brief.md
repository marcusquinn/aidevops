## What

Two shell test fixtures fail every case on `main` because they copy `shared-*.sh` into a temporary agents tree but not `gh-closing-reference-lib.sh`, which `shared-gh-wrappers-safe-edit.sh` now sources.

## Why

`test-plugin-subagent-index.sh` (4/4 failing) and `test-agent-source-manifest-index.sh` (5/5 failing) report only the missing-file error, so they no longer cover the subagent index or the capability registry. Observed on `main` at `88b0d6ff09` and on the GH#37155 branch:

```text
.../.aidevops/agents/scripts/shared-gh-wrappers-safe-edit.sh: line 663: .../.aidevops/agents/scripts/gh-closing-reference-lib.sh: No such file or directory
```

The source line came in with GH#36797 / GH#36877 (`gh-closing-reference-lib.sh`).

## How

- Pattern: each fixture already copies helper dependencies one by one (`test-plugin-subagent-index.sh:44-51`, `test-agent-source-manifest-index.sh:41-44`). Add `cp "$REPO_ROOT/.agents/scripts/gh-closing-reference-lib.sh" "$agents_dir/scripts/"` next to the `shared-*.sh` copy in both.
- Check `test-agent-sources-core-layout.sh` and other fixtures that copy `shared-*.sh` (`rg -n 'shared-\*\.sh' .agents/scripts/tests/`) for the same gap. Fix only the fixtures that actually fail.
- Do not change `shared-gh-wrappers-safe-edit.sh`.

### Files Scope

- .agents/scripts/tests/test-plugin-subagent-index.sh
- .agents/scripts/tests/test-agent-source-manifest-index.sh

## Acceptance

- `bash .agents/scripts/tests/test-plugin-subagent-index.sh` reports 4/4 passed.
- `bash .agents/scripts/tests/test-agent-source-manifest-index.sh` reports 5/5 passed.

## Verification

- Run both tests above, then `shellcheck` on the edited test files.
