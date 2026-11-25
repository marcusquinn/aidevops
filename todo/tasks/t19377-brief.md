## What

Make `issue-sync-helper.sh refresh-body` print why it refused instead of exiting 1 with no output.

## Why

Observed twice on 2026-11-25: `issue-sync-helper.sh refresh-body <N> --repo <owner/repo> --body-file <brief> --dry-run` on an open interactive issue claimed only by the caller exited 1 after about 20 s and printed nothing. The issue carried `status:in-review`, which `interactive-session-helper.sh claim` applies. `_refresh_policy` (`.agents/scripts/issue-sync-helper-refresh.sh:128-135`) refuses `status:queued`, `status:in-progress` and `status:in-review` whoever holds the claim. GH#32652 made that refusal deliberate, because a worker may be reading the body. The refusal path at lines 80-83 writes only an audit receipt and returns 1, so the caller cannot tell a policy refusal from a crash or a missing permission, and the session gave up on the refresh. Other `|| return 1` exits in `cmd_refresh_body` (lines 78, 84-98) are silent in the same way.

The refusal policy stays as it is. This task only reports the reason.

## How

### Files Scope

- `.agents/scripts/issue-sync-helper-refresh.sh`
- `.agents/scripts/tests/test-issue-sync-refresh-body.sh`

### Changes

1. In `_refresh_policy`, or a small `_refresh_policy_reason` helper beside it, find the first failing condition and print it with `print_error` before returning 1. Use one line naming the cause and the next step:
   - invalid state → `Refresh refused: issue state could not be validated`
   - not OPEN → `Refresh refused: issue #N is <STATE>`
   - non-self claim → `Refresh refused: issue #N is claimed by <login>`
   - status label → `Refresh refused: issue #N has <label> (a worker may be reading the body); retry after the label clears`
   Keep the existing `_refresh_audit blocked` calls. Do not change which states are refused.
2. Give every remaining bare `return 1` in `cmd_refresh_body` a `print_error` naming the step that failed (for example the empty `self_login` at line 78, temp-file creation, tail extraction and hashing). Follow the existing `print_error "Refresh requires maintainer authority"` style.
3. In the test, which stubs `print_error` to stderr at line 13, capture stderr for the CLOSED case (line 49) and the `status:queued` case (line 51). Assert each contains its reason line. Use the file's existing `if cmd ...; then exit 1; fi` pattern.

## Acceptance

- `bash .agents/scripts/tests/test-issue-sync-refresh-body.sh` prints PASS, and the CLOSED and `status:queued` cases assert a non-empty reason on stderr.
- Running `refresh-body ... --dry-run` against an open issue labelled `status:in-review` exits 1 and prints the `status:in-review` reason line.
- Refused states and exit codes are unchanged: dry-run with a diff still returns 2, and a no-op still returns 0.
- ShellCheck is clean on both files.
