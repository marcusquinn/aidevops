## What

Make `gh-checks-wait-helper.sh wait` (and therefore `full-loop-helper.sh wait-checks`) default to the worker contract's 200-second timeout when it runs inside a headless worker and the caller passed no `--timeout`. Interactive sessions, explicit `--timeout` values and the `AIDEVOPS_GH_CHECKS_TIMEOUT_SECONDS` override keep their current behaviour (1800 seconds by default).

## Why

t19011 (PR #38390) made headless workers own their PR through merge by waiting in bounded chunks: `full-loop-helper.sh wait-checks "$PR_NUMBER" --repo "$WORKER_REPO_SLUG" --timeout 200`, at most 8 times (`.agents/scripts/headless-runtime-contract.sh` Mandatory behavior 8). When a worker omits `--timeout`, the helper falls back to 1800 seconds. That is longer than the 600-second OpenCode shell tool limit and the 600-second activity-watchdog stall window (`WORKER_STALL_TIMEOUT`). A single wait call then emits no worker output for 600 seconds. The watchdog confirms a stall, and once total elapsed time passes the 1500-second cap (`WORKER_STALL_HARD_KILL_SECONDS`) it kills the worker as `hard_kill_cap_active`.

Evidence from `worker-activity-helper.sh summary` (24 hours to 2026-11-15T22:28Z): 6 `elapsed_cap_while_active` kills out of 120 terminal outcomes.

- One worker on a private managed repository ran `full-loop-helper.sh wait-checks <PR> --repo <owner/repo>` with no `--timeout`. The shell tool ended the call after 600000 ms, and the worker was then killed with `exit_code=124 kill_reason=hard_kill_cap_active` after its PR already existed.
- A second worker's failure excerpt on the same repository also ends inside a `wait-checks` call.
- The other four kills were different long silent calls (raw `gh pr checks --watch`, `pnpm install … | tail -5`, a filesystem-wide `fd` from `/`). They are out of scope here.

The contract already states the 200-second chunk, so the helper default just makes the contract hold when a model drops the flag.

## How

In the `wait` option parser of `.agents/scripts/gh-checks-wait-helper.sh` (around line 896):

1. Record whether `--timeout` was passed explicitly.
2. After parsing, if it was not passed, `AIDEVOPS_GH_CHECKS_TIMEOUT_SECONDS` is unset, and the process is a headless worker (`FULL_LOOP_HEADLESS` or `AIDEVOPS_HEADLESS` or `OPENCODE_HEADLESS` set to `true` or `1`, matching the markers listed in `detect_session_origin`, `.agents/scripts/shared-gh-wrappers-session.sh:111`), use `AIDEVOPS_GH_CHECKS_HEADLESS_TIMEOUT_SECONDS` (default 200).
3. Document the headless default in `usage`.

`full-loop-helper-merge.sh:889` passes `--timeout 0` explicitly and stays unchanged. No other non-test caller invokes `wait` without `--timeout`.

## Acceptance

- New cases in `.agents/scripts/tests/test-gh-checks-wait-helper.sh`:
  - with `FULL_LOOP_HEADLESS=true` and no `--timeout`, a pending wait times out under the headless default (exercise it with `AIDEVOPS_GH_CHECKS_HEADLESS_TIMEOUT_SECONDS` set to a small value) and returns exit 8;
  - an explicit `--timeout` still wins under headless;
  - with no headless markers, the default stays 1800.
- `bash .agents/scripts/tests/test-gh-checks-wait-helper.sh` passes, and ShellCheck is clean on both files.

## Files Scope

- `.agents/scripts/gh-checks-wait-helper.sh`
- `.agents/scripts/tests/test-gh-checks-wait-helper.sh`
