## Origin

- **Created:** 2026-11-19, interactive session root-causing why `test-browser-qa-helper.sh` was red on `main` for 18 days (#39173, fixed by #39175)
- **Evidence:** `.agents/scripts/affected-tests-helper.sh:101` selects suites only for changed files with suffix `.sh` or `.py`. #36329 (GH#36325, commit `c7d08421fa`) changed `.agents/scripts/playwright-runtime.mjs`, `browser-mcp-launcher.sh`, `mcp-setup.sh` and `mcp-registry.mjs`. `test-browser-qa-helper.sh` names `playwright-runtime.mjs` (line 9: `PLAYWRIGHT_RUNTIME="${SCRIPT_DIR}/../playwright-runtime.mjs"`), but the `.mjs` change selected nothing. The advisory `Affected script suites` job therefore never ran the suite that #36329 broke.

## What

Make `affected-tests-helper.sh` select shell suites that name a changed JavaScript/TypeScript script under `.agents/scripts/` (`.mjs`, `.cjs`, `.js`, `.ts`), the same way it already does for `.py`, using a direct filename match with hop distance 0.

## Why

`.agents/scripts/` contains about 250 tracked `.mjs`/`.js`/`.cjs`/`.ts` files (`git ls-files '.agents/scripts/*.mjs' ...`), and 52 shell suites name a `.mjs` file (`rg -l --fixed-strings .mjs .agents/scripts/tests/ --glob 'test-*.sh'`). At the moment, every PR that changes only those runtime files gets `No affected suites`, so regressions in them can only be caught by tests that happen to be wired into required jobs.

## Tier

`tier:simple`: a one-line suffix-tuple edit plus a comment, in one file.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/affected-tests-helper.sh:101`: extend the suffix tuple of the non-test branch.

### Implementation Steps

1. Replace line 101:

```python
    elif path.suffix in (".sh", ".py") and "tests" not in path.parts:
```

with:

```python
    # GH#39173: JS/TS runtimes (e.g. playwright-runtime.mjs) are exercised by
    # shell suites that name them; select those suites like .py (name match, hop 0).
    elif path.suffix in (".sh", ".py", ".mjs", ".cjs", ".js", ".ts") and "tests" not in path.parts:
```

   Non-`.sh` files already take the `related = {path.name: 0}` branch (lines 102-105), so no other change is needed.
2. Run ShellCheck on the file, then do the selection check under Verification.

### Complete Write Surface

- **Callers/readers:** `.github/workflows/code-quality.yml:49` (`affected-tests-helper.sh run --base ... --compare-base`, advisory job), plus local `full-loop` / PR-body evidence that cites its classification.
- **Writers/mutation paths:** N/A. The helper is read-only apart from a temporary base worktree that `--compare-base` already creates.
- **Existing verification/tests:** none dedicated (`rg -l affected-tests .agents/scripts/tests/` is empty). Verify through the production `list` command below.
- **Schemas/config, mirrors, migrations, cleanup:** N/A for schemas, migrations and cleanup. `setup.sh` deploys the script unchanged.

### Hazards and Compatibility

- **Concurrency/atomicity:** none.
- **Migration/rollback:** a trivial one-line revert.
- **Mixed-version/backward compatibility:** more suites may be selected for PRs that touch JS/TS. `--max 30` still caps the run, and the specificity ranking keeps the most specific suites first. Report any cap overflow from the verification run in the PR body.
- **Idempotency/retry:** unchanged.
- **Partial failure/recovery:** unchanged. The job stays advisory (`continue-on-error: true`).

### Verification Before Dispatch

```bash
# In the worker worktree: make a throwaway uncommitted edit to a .mjs runtime, list, then revert.
printf '\n// probe\n' >> .agents/scripts/playwright-runtime.mjs
.agents/scripts/affected-tests-helper.sh list --base origin/main   # must include .agents/scripts/tests/test-browser-qa-helper.sh
git checkout -- .agents/scripts/playwright-runtime.mjs
.agents/scripts/affected-tests-helper.sh list --base origin/main   # back to baseline (only suites for this PR's own diff)
shellcheck .agents/scripts/affected-tests-helper.sh
```

- **Surface mapping:** the first `list` proves JS selection works. The second `list`, after the revert, proves no spurious selection. ShellCheck covers lint.
- **Broad verification trigger:** not required.

### Scope Boundaries

**Hard boundaries:** do not make the `affected-script-tests` job required. Do not change `pre-existing` classification semantics. Do not add test harnesses.

### Files Scope

- `.agents/scripts/affected-tests-helper.sh`

## Acceptance Criteria

- [ ] With an uncommitted change to `.agents/scripts/playwright-runtime.mjs`, `affected-tests-helper.sh list --base origin/main` lists `.agents/scripts/tests/test-browser-qa-helper.sh`.
- [ ] Regression guarantee: a changed file under `.agents/scripts/tests/` with a JS suffix (e.g. `tests/test-ci-runner-routing.mjs`) still does not select suites by name, because the `"tests" not in path.parts` guard is kept, and `.sh` changes still follow the transitive sourcer expansion (lines 102-103 unchanged).

## Context & Decisions

- Correction to #39173's brief: it said no CI workflow runs `test-browser-qa-helper.sh`. More precisely, only the advisory affected-suite job can run it, and only for `.sh`/`.py` changes, which is how the `.mjs` regression went unnoticed. Making the suite a required gate is tracked separately.
