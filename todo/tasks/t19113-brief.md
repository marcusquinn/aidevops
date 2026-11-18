## What

Headless workers die partway through finished work when they wait on a long `aidevops_bounded_operation` command. OpenCode's built-in `doom_loop` guard fires when the last three parts of the current assistant message are identical tool calls (for example `{"action":"status","operation_id":"op_…","wait_seconds":60}`). In OpenCode 1.19 each step is a new assistant message, so this fires only when one response fans out three identical calls in parallel; sequential polls across steps never trigger it. The OpenCode session DB shows workers doing exactly that before the rejection. The headless permission broker classifies `doom_loop` as non-grantable, rejects it, and the worker session ends with `permission_required`.

Evidence from one runner on 2026-11-18 (OpenCode 1.19.6):

- `~/.aidevops/logs/worker-progress-blockers.jsonl`: six `permission_request_non_grantable` events with `permission=doom_loop tool=aidevops_bounded_operation` between 15:28Z and 18:18Z, on three managed-repo issues. Before today there were only three in two weeks.
- The worker failure excerpts for two of them show the worker had pushed commits (and in one case opened a draft PR), then polled the same running publish operation with identical `status` arguments. The log line `permission requested: doom_loop (aidevops_bounded_operation); auto-rejecting` is followed by `[WORKER_EXIT_DIAGNOSTICS] cause=permission_required`. The completion work (publish receipt, PR finalisation) was lost and the issue went back into the queue.
- The installed OpenCode binary raises `doom_loop` with `patterns:[toolName]` and `metadata:{tool, input}`, and no call ID. So the broker can see exactly which call repeated.

Designed polling is the documented way to wait on a bounded operation. `.agents/plugins/opencode-aidevops/session-continuation-loops.mjs` already exempts it as `isDesignedPoll()` from aidevops' own loop detector. The status/output actions are read-only and each response reports new elapsed time, so repeating them is not a loop. GH#37625 hit the same guard with `sleep 60` and was closed with a prose-only change to `pulse-sweep.md`. A deterministic rule is needed.

## How

- NEW `.agents/plugins/opencode-aidevops/permission-broker-designed-poll.mjs`: export `isDesignedPollDoomLoop(request)`. It returns true only when `permission` (or the legacy `type`) is `doom_loop`, the tool (`metadata.tool`, falling back to the single entry in `patterns`) is `aidevops_bounded_operation`, and `isDesignedPoll(tool, metadata.input)` holds, which means `action` is `status` or `output`. Reuse `isDesignedPoll` from `session-continuation-loops.mjs` and do not copy the regex.
- EDIT `.agents/plugins/opencode-aidevops/permission-broker.mjs`: in `handlePermissionEvent` reply `once`, and in `handlePermissionAsk` set `output.status = "allow"`, for a designed-poll doom loop. Do this before the impossible-read and capture paths, and record one non-blocking `permission_designed_poll_allowed` event, the way `recordReadOnlyRootAllow` does. Everything else is unchanged: `start`/`cancel` repeats, other tools' doom loops, and every non-`doom_loop` permission keep today's capture and reject.
- EDIT `.agents/plugins/opencode-aidevops/tests/test-permission-broker.mjs`: add one test. A status or output doom loop is allowed on both the event and hook paths, with no capture file. A `start` doom loop on the same tool, and a `bash` doom loop, are still captured as non-grantable and rejected.

### Files Scope

- .agents/plugins/opencode-aidevops/permission-broker-designed-poll.mjs
- .agents/plugins/opencode-aidevops/permission-broker.mjs
- .agents/plugins/opencode-aidevops/tests/test-permission-broker.mjs
- TODO.md

## Acceptance Criteria

- [ ] In a headless session, a `doom_loop` ask for `aidevops_bounded_operation` with `action` `status` or `output` is answered `once` on the event path and `allow` on the hook path, and writes no permission capture.
- [ ] A `doom_loop` ask for `aidevops_bounded_operation` with `action` `start` or `cancel`, or for any other tool, is still captured as non-grantable and rejected.
- [ ] Interactive (non-headless) behaviour is unchanged.
- [ ] `node --test .agents/plugins/opencode-aidevops/tests/test-permission-broker.mjs` passes.

## Verification

- `node --test .agents/plugins/opencode-aidevops/tests/test-permission-broker.mjs`
- After deploy: `rg '"permission":"doom_loop"' ~/.aidevops/logs/worker-progress-blockers.jsonl | rg -c aidevops_bounded_operation` stops growing, and `permission_designed_poll_allowed` events appear instead.
