## What

Cut the required `Framework Validation` check's wall time from ~12 minutes to roughly the slowest independent group (~4-5 minutes). Run its independent step groups as parallel jobs, gated by one aggregator job that keeps the exact required context name `Framework Validation`.

## Why

`Framework Validation` is the last required check to finish on most PRs, so it sets merge latency for every worker and interactive PR. It runs 19 steps serially in one job. On PR #38920 (head a8e398b2, 2026-11-18) the job took 731s, against 335s for ShellCheck and 330s for Complexity Analysis, the next-slowest required checks. Step timings from job 134469393895:

- Profile README Boundary Guard 165s
- Profile README Contributions Fail-Closed Guard 167s (including ~30s apt/dbus setup)
- Pulse-merge Regression Suites 160s (`test-full-loop-merge.sh` alone is 159s inside the parallel xargs)
- Worker Count and Capacity Tests 83s
- Reusable Workflow Contracts 41s
- Checkout 36s
- Vault 26s
- Pulse Wrapper Canary 25s
- Everything else under ~20s

These groups share no state, so the serial sum is pure waiting. The repo is public, so the extra runner minutes (three more checkouts) are free. Faster merges also shrink the window for base drift and rebase conflicts between concurrent worker PRs.

## How

- EDIT: `.github/workflows/code-quality.yml` job `framework-validation` (~line 393-716). Split it into four jobs with the same `needs: detect-scope` and `if: needs.detect-scope.outputs.substantive == 'true'`, the same `runs-on: ubuntu-latest`, and the same checkout (`fetch-depth: 0`):
  - `framework-validation-core`: all steps except the three below.
  - `framework-validation-profile-boundary`: Profile README Boundary Guard.
  - `framework-validation-profile-contributions`: Profile README Contributions Fail-Closed Guard (with its useradd/dbus setup).
  - `framework-validation-pulse-merge`: Pulse-merge Regression Suites (keep `timeout-minutes: 20`).
- Keep job id `framework-validation` with `name: Framework Validation` as the aggregator:
  - `needs: [detect-scope, <the four jobs>]`
  - `if: ${{ !cancelled() && needs.detect-scope.outputs.substantive == 'true' }}`
  - no checkout; one step that fails unless every shard result is `success`
  Docs-only PRs still skip it, as today.
- Shard job `name:` values must not equal any required context (for example `Framework Validation (core)`).
- EDIT: `.agents/scripts/tests/test-ci-runner-routing.mjs` line 13: update the pinned `runs-on` selector count (13) by the number of added jobs. Each new job uses `ubuntu-latest`.

### Files Scope

- `.github/workflows/code-quality.yml`
- `.agents/scripts/tests/test-ci-runner-routing.mjs`

## Acceptance

- Required context `Framework Validation` still reports on every substantive PR. It succeeds only when all four shards succeed, fails when any shard fails, and is skipped on docs-only PRs.
- On this PR, `Framework Validation` completes in well under the 731s baseline. Report the observed duration in the PR body.
- No step is dropped or changes behaviour; each moves verbatim into its shard.

## Verification

```bash
node --test .agents/scripts/tests/test-ci-runner-routing.mjs
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/code-quality.yml'))"
actionlint .github/workflows/code-quality.yml   # if installed
gh pr checks <PR> --repo marcusquinn/aidevops --required
```
