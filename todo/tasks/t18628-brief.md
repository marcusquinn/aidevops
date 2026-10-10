## What

Replace the 20 copy-pasted `_aidevops_path_prefix` bootstrap blocks with one
shared helper in `.agents/scripts/runtime-env.sh`.

## Why

Follow-up from t18626 (PR #34076) review. Every launchd/cron entrypoint
carries the same 6-line block that appends Homebrew, `/usr/local/bin`,
Linuxbrew and `/bin:/usr/bin` to the inherited PATH. The fallback list is
duplicated 20 times, differs from the `runtime-env.sh` fallback, adds missing
dirs and duplicates, and forks `uname` just to decide on Linuxbrew.

## How

- `runtime-env.sh`: add `AIDEVOPS_DAEMON_PATH_FALLBACK` and
  `aidevops_use_daemon_path` (inherited PATH first, then existing fallback
  dirs; builtins only, safe before `dirname` is reachable).
- Each script: replace the block with the sibling-source convention already
  used by `shared-constants.sh:21-23`.
- `tests/test-pulse-path-precedence.sh`: exercise the new bootstrap line
  instead of extracting the old block with awk.

### Files Scope

- .agents/scripts/runtime-env.sh
- .agents/scripts/complexity-scan-runner.sh
- .agents/scripts/contribution-watch-helper.sh
- .agents/scripts/dashboard-freshness-check.sh
- .agents/scripts/detect-app-type.sh
- .agents/scripts/draft-response-helper.sh
- .agents/scripts/efficiency-analysis-runner.sh
- .agents/scripts/foss-contribution-helper.sh
- .agents/scripts/foss-handlers/generic.sh
- .agents/scripts/foss-handlers/macos-app.sh
- .agents/scripts/foss-handlers/wordpress-plugin.sh
- .agents/scripts/pulse-merge-routine.sh
- .agents/scripts/pulse-merge-webhook-receiver.sh
- .agents/scripts/pulse-repo-tier-classifier-routine.sh
- .agents/scripts/pulse-repo-tier.sh
- .agents/scripts/pulse-session-helper.sh
- .agents/scripts/pulse-wrapper.sh
- .agents/scripts/routine-log-helper.sh
- .agents/scripts/stats-wrapper.sh
- .agents/scripts/upstream-watch-helper.sh
- .agents/scripts/worker-watchdog.sh
- .agents/scripts/tests/test-pulse-path-precedence.sh

## Acceptance

- `git grep _aidevops_path_prefix -- .agents` returns nothing.
- Configured PATH keeps precedence; empty/unset PATH gets existing fallbacks
  with no empty entries (test-pulse-path-precedence.sh, test-runtime-env.sh).
- ShellCheck clean; PATH portability workflow green on ubuntu and macOS.
