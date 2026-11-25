## What

When a worker names the input owner by GitHub login
(`TERMINAL_BLOCKER_INPUT_OWNER=<login>`) instead of a role, map that login
through its verified permission on the dispatch repository: admin → `admin`,
maintain or write → `maintainer`. The report then becomes an
`input_required:<role>` hold that publishes its question. Any other permission,
or an unreadable answer, keeps today's `unknown` class.

## Why (evidence, 2026-11-25)

- An issue in a managed private repo (#20518 there) has been redispatched for days.
  Its latest worker said: "The 17th session finished the same re-verification a
  few hours ago … nothing has changed since … re-capturing without a new input
  only repeats earlier sessions." It ended with
  `TERMINAL_BLOCKER_REASON=input_required`,
  `TERMINAL_BLOCKER_INPUT_OWNER=<repo admin login>` and a
  `TERMINAL_BLOCKER_QUESTION` (close out with held rows, or file a builder
  process issue?).
- `terminal-blocker-circuit.sh` capture accepted only
  `user|contributor|maintainer|admin` as the owner, so it emitted `unknown`.
  Because the reason was explicit, AI triage was skipped
  (`terminal_blocker_triage skipped:explicit_or_empty` in the worker log).
  Unknown never opens a circuit (`terminal_blocker_circuit_comment` returns
  early) and only applies the 15 min → 24 h backoff. Merged partial PRs reset
  that count, so the issue went back to `status:available` + `auto-dispatch`
  after every release, and the question was never published or answered.
- Today's per-issue worker logs show 17 issues whose final report was a no-op
  ("made no changes", "nothing new to do"). This change fixes the
  login-owner subset.

## How

- `.agents/scripts/terminal-blocker-circuit.sh`
  - Capture program: when `input_required` has exactly one owner that is not a
    role but matches a login shape, emit `unknown` with `ask_login` and make
    `TERMINAL_BLOCKER_QUESTION` eligible.
  - New `_terminal_blocker_login_owner_class`: one REST read,
    `repos/<slug>/collaborators/<login>/permission` (`role_name`, falling back to
    `permission`). It prints `input_required:admin|maintainer` or `unknown`.
  - `terminal_blocker_capture_output` calls it for `unknown` captures with
    `ask_login`, and clears the question unless the class becomes input_required
    (same pattern as `_terminal_blocker_permission_ask_class`).
- Trust boundary: the role only selects who is asked. Release still requires the
  existing OWNER/MEMBER answer, brief revision or retry evidence.
- `.agents/reference/worker-integration-recovery.md`: document the mapping.

## Files Scope

- `.agents/scripts/terminal-blocker-circuit.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`
- `.agents/reference/worker-integration-recovery.md`

## Acceptance

- A login with admin, maintain or write permission yields `input_required:admin` or
  `input_required:maintainer`, with the question captured.
- A login with read or unknown permission, a non-login value and a missing owner stay
  `unknown` with no question. The existing `human` owner cases are unchanged.
- Live: replaying the real #20518 worker log through the patched capture yields
  `input_required` owner `admin` with the question. The deployed script yields
  `unknown` with no question.

## Verification

- `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh` (65 run, 0 failed)
- `shellcheck -x -P .agents/scripts .agents/scripts/terminal-blocker-circuit.sh .agents/scripts/tests/test-terminal-blocker-circuit.sh`
- Live replay with `DISPATCH_REPO_SLUG=<repo>` and a temporary
  `AIDEVOPS_WORKER_BLOCKER_LOG_FILE`.

## Follow-up (not in scope)

Other no-op redispatch classes from the same census: stale merge-conflict feedback
after the referenced PR merged; done phases left open by `For #N` PRs; and blocked
reports re-run before their dated hold. These are tracked separately.
