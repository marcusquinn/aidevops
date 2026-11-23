<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `affected-tests-helper sourced module vacuous pass parent suite` → 0 relevant hits.
- [x] Discovery pass: no open issue or PR covers affected-test selection of sourced modules (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:standard`. One embedded Python selector change plus a stderr report.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (worker throughput investigation, GH#39209 follow-up)
- **Conversation context:** GH#39167 (`3baf2eeeb0`) changed `.agents/scripts/shared-claim-lifecycle.sh` and `.agents/scripts/shared-pr-base.sh`. Its CI affected-test gate passed, but on `main` afterwards `bash .agents/scripts/tests/test-headless-runtime-helper.sh` aborted at `rc=1` before printing `Tests run`/`Failures`. Its orphan-recovery fixtures still stubbed `gh repo view` while the new resolver reads `gh api repos/<slug>` (fixed in GH#39209). Regressions like this reach workers and then need interactive sessions to diagnose.

## What

`.agents/scripts/affected-tests-helper.sh:52-60` selects every `tests/test-*.sh` whose text contains a changed script's basename. Split suites keep their cases in sourced-only modules (header `# Sourced by ...`; 36 such files today). A changed library is usually named only in the module, so the module is selected and the runnable parent suite is not. Running a module on its own just defines functions: `bash .agents/scripts/tests/test-headless-runtime-completion-tests-recovery.sh` exits `0` with 0 output lines. The gate therefore reports a vacuous pass.

Make selection resolve each selected test file that another test file sources (`source`/`.` line naming its basename) to the root suite(s) that transitively source it, and run those roots instead of the module. Report each module→root mapping and every suite omitted by `--max` on stderr, so the CI step summary shows what did not run.

## Why

The CI gate (`.github/workflows/code-quality.yml:49`, `affected-tests-helper.sh run --base origin/${BASE_REF} --compare-base`) is the only automated test run for most PRs. A vacuous pass lets shared-library regressions merge green. Workers then hit them in production paths or red local suites, and interactive sessions have to diagnose them, which is the user-time cost aidevops exists to remove.

## Tier

`tier:standard`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/affected-tests-helper.sh:50-64`. After computing `selected`, build a sourcer map over `tests`: for each test file, the set of other test basenames named on lines matching `^\s*(source|\.)\s+`. Replace each selected file that has sourcers with its root sourcers (files no other test sources), using a visited set against cycles. Print `module <m> -> <roots>` lines and an `omitted by cap: <names>` line to stderr.

### Files Scope

- `.agents/scripts/affected-tests-helper.sh`

### Reference pattern

- Parent/module sourcing: `.agents/scripts/tests/test-headless-runtime-helper.sh:115` sources `test-headless-runtime-completion-tests.sh`, which sources `-finish.sh` and `-recovery.sh` at `:793`/`:796`. Other examples: `test-gh-shim.sh:461`, `test-pr-checkpoint-continuation-helper.sh:161` (sources via `${TEST_SCRIPT_DIR}`).

### Non-goals / known limits

- Transitive non-test sourcing (a changed library sourced by another script that tests name) stays out of scope: `shared-constants.sh` would select every suite.
- Per-suite timeout: the default `--timeout 240` is below the ~440s the headless parent suite takes locally. A suite that times out on head and base is classed `pre-existing`. Record a timeout as its own visible class only if it stays small; otherwise file a follow-up.

## Acceptance Criteria

- [ ] With an uncommitted edit to `.agents/scripts/shared-claim-lifecycle.sh`, `.agents/scripts/affected-tests-helper.sh list --base origin/main` lists `.agents/scripts/tests/test-headless-runtime-helper.sh` and does not list `test-headless-runtime-completion-tests-recovery.sh`.
- [ ] No file printed by `list` contains a `# Sourced by` header (`rg -l '^# Sourced by'` over the listed files is empty).
- [ ] stderr shows the module→root mapping and names any suites omitted by `--max`.
- [ ] ShellCheck is clean for `.agents/scripts/affected-tests-helper.sh`; `python3 -m py_compile` on the extracted heredoc succeeds.
