## What

`release_notify_unsigned` in `.agents/scripts/cloudron-release-approval-helper.sh` never posts the unsigned-request notice on macOS. Line 1092 parses the request's `created_at` with GNU-only `date -d "$created" +%s`; BSD `date` rejects `-d` (`date: illegal option -- d`), the `|| return 0` swallows it, and the notice is silently disabled. Use the framework's portable ISO-8601 parse instead.

## Why

- GH#39788 added the notice so a maintainer learns when a non-routine Cloudron release request waits unsigned past 24 h. Routines on macOS runners (the maintainer's machine) never emit it, so held release PRs wait with no prompt.
- Reproduction on macOS: `bash .agents/scripts/tests/test-cloudron-release-approval.sh` fails at `FAIL notice_old notices=0 expected=1` (fixture `created_at` is the fixed `2020-01-01T00:00:00Z`, so this is not clock drift). `date -d 2020-01-01T00:00:00Z +%s` prints `date: illegal option -- d`. Linux CI passes, which is why the defect merged.
- `affected-tests-helper.sh` reports this suite as a regression for any PR touching `full-loop-helper-risk.sh` (it sources that file), which misleads unrelated PRs run on macOS.

## How

1. In `release_notify_unsigned` (`.agents/scripts/cloudron-release-approval-helper.sh:1092`), replace the parse with the existing portable pattern, for example `.agents/scripts/pulse-nmr-approval.sh:789`: `date -u -d "$created" '+%s' 2>/dev/null || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$created" '+%s' 2>/dev/null`, keeping the best-effort `|| return 0`.
2. Check the same file for any other `date -d` use and apply the same pattern.

### Files Scope

- `.agents/scripts/cloudron-release-approval-helper.sh`

## Acceptance

- On macOS, `bash .agents/scripts/tests/test-cloudron-release-approval.sh` passes, including `PASS unsigned-request notice: once per head, PR-only, age-gated`.
- The Linux CI result for that suite is unchanged.

## Verification

- `shellcheck -x .agents/scripts/cloudron-release-approval-helper.sh`
- `bash .agents/scripts/tests/test-cloudron-release-approval.sh` on macOS and in CI.
