<!-- aidevops:brief-schema=v2 -->
# t18896: Release coordination over the session bus: lane owner session, held-lane hints and release notices

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive ses_e480fcfa0ffeCzemlBnZ5j1VBA (t18886 session bus, GH#37149, PR #37165, released in v3.39.136)
- **Created by:** ai-interactive
- **Conversation context:** The owner named releases as a common need for session-to-session messaging. Evidence from this session on 2026-11-08: another session's release lane (source PR #37182) had created the tag `v3.39.136`, but its executor had died (`RELEASE_EXECUTOR` state `dead`, `process-absent`). This session only saw "A different source owns the active release lane", with no way to tell which session owned it or whether that session was still alive. It recovered with `aidevops release reconcile 37182` (provenance PR #37234). Its own merged PR #37165 went out in that release, but no session was told when the publication finished.

## What

1. **Lane owner session:** when a release lane is acquired, or its executor is captured or re-captured, record an advisory `owner_session: { session_id, captured_at }` from `AIDEVOPS_OPENCODE_SESSION_ID` (else `OPENCODE_SESSION_ID`). It is informational only and never used for ownership, recovery or authority decisions.
2. **Held-lane hint:** when a release command is refused because another source holds the lane, print the owner session's handle, status and last activity from `aidevops sessions show <session_id> --json`. Then print a ready-to-run `aidevops sessions ask <handle> "…"` line. When the owner session is not live, say so next to the existing executor liveness line and recovery command.
3. **Release notices:** `aidevops sessions watch-release <owner/repo>` (and an `aidevops_sessions` `watch-release` action) subscribes the caller's root session. On `release_lane_finalize`, and when liveness first observes a dead executor for an active lane, a best-effort `info` notice goes to every subscriber and to the lane owner session. The notice carries the repo, source PR, tag, receipt or executor state, and the recovery command. Subscriptions expire after 7 days or once the session has no presence.

## Why

Release lanes already serialise publication safely, but sessions cannot see who holds a lane. The owner ends up relaying "is anyone releasing?" between sessions, and a dead executor is found only when someone else tries to release. Recording the owner session and sending notices turns those into one-hop questions over the bus.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** This touches release-lane state on a trust boundary. The new field must be provably advisory, and notices must never change release exit codes or timing.

## How (Approach)

- **Capture:** `_release_lane_executor_capture` (`.agents/scripts/release-lane-liveness.sh:9-12`) calls `release-lane-owner.py capture` (`release-lane-owner.py:62-65`). Add `owner_session` alongside `executor` wherever the executor is captured: acquire (`release-lane-helper.sh:597`), and the recovery and reclaim captures at `:496-500`, `:533-540` and `:643-644`. Validate the session ID with the same safe-ID rule the bus uses (`isSafeId`), else write `null`.
- **Advisory marker:** add a `#aidevops:trust-boundary` comment where the field is written, stating that `owner_session` must never be read for ownership or recovery. Add a test that a lane whose `owner_session` names a live session but whose executor is dead is still recoverable exactly as today.
- **Hint:** the refusal paths are `release_lane_acquire` (`ACTIVE_RELEASE_LANE …`, `release-lane-helper.sh:610-612`) and `_full_loop_release_existing_with_lane` (`full-loop-release-helper.sh:602-630`, "A different source owns the active release lane"). After the existing lines, call a new `release_lane_owner_session_hint` in `release-lane-liveness.sh`. It runs `aidevops sessions show` with a 5 s timeout and prints nothing on any failure.
- **Notices:** a new `release_lane_notify` in `release-lane-liveness.sh` runs `aidevops sessions notify-release --repo … --source-pr … --event published|superseded|failed|executor-dead --tag … --receipt …`. Call it after a successful `release_lane_finalize` write (`release-lane-helper.sh:1292-1325`) and from `release_lane_liveness_report` (`release-lane-liveness.sh:22-60`) when it observes `dead` for an active lane. A `notified_dead_at` marker in the bus subscription store makes sure the dead-executor notice is sent only once. Run it in the foreground with a timeout, ignore its exit code, and keep the caller's return value unchanged.
- **Bus side:** add `watch-release` and `notify-release` commands to the session-bus CLI. Subscriptions live in a new `release-watch/<repoKey>/<sessionID>.json` tree. The existing `subs/<sessionID>/` tree (`session-bus-files.mjs:95`) is keyed by session ID, so release watches stay separate from it. `notify-release` sends with `origin: "cli"` and `type: "info"`, so it never wakes an idle session and only shows a toast and the next-turn delivery.

### Files to Modify

- EDIT: `.agents/scripts/release-lane-helper.sh`: record `owner_session` at capture sites, notify after finalize, hint after the acquire refusal.
- EDIT: `.agents/scripts/release-lane-liveness.sh`: `release_lane_owner_session_hint`, `release_lane_notify`, and the dead-executor notice.
- EDIT: `.agents/scripts/full-loop-release-helper.sh`: hint after the "different source" refusal.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs` and `session-bus-cli.mjs`: `watch-release`, `notify-release`.
- NEW: `.agents/plugins/opencode-aidevops/session-bus-release.mjs`: subscription store and notice fan-out.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`: `watch-release` action.
- EDIT: `.agents/scripts/tests/test-release-lane.sh` and `.agents/scripts/tests/test-release-lane-liveness.sh`: owner field, hint output, notify call and unchanged exit codes.
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`: subscription and fan-out cases.
- EDIT: `.agents/scripts/setup/modules/agent-deploy.sh`: add the new module to the plugin freshness list.
- EDIT: `.agents/reference/session-bus.md`, `.agents/workflows/release.md`: document the hint and notices (short pointer in `release.md`).

### Complete Write Surface

- **Callers/readers:** `aidevops release status|reconcile|recover-reservation` and full-loop release lanes read the lane JSON; `release_lane_liveness_report` prints executor state; all of them must ignore `owner_session` for decisions.
- **Writers/mutation paths:** lane writes through `_release_lane_write` (compare-and-swap) at the capture sites listed above; bus writes through `sendMessage` (`session-bus-messages.mjs:104`) and the new subscription store.
- **Existing verification/tests:** `bash .agents/scripts/tests/test-release-lane.sh`, `bash .agents/scripts/tests/test-release-lane-liveness.sh`, `bash .agents/scripts/tests/test-release-lane-reservation.sh`, `python3 .agents/scripts/tests/test-release-lane-owner.py`, `npm test --prefix .agents/plugins/opencode-aidevops`.
- **Schemas/config:** lane JSON gains optional `owner_session`; bus gains `release-watch/`. `AIDEVOPS_RELEASE_NOTICES=false` disables the notify and hint calls.
- **Generated/deployed mirrors:** `.agents/scripts/setup/modules/agent-deploy.sh` plugin freshness list; scripts deploy through `setup.sh`.
- **Migrations/backfills:** not applicable because existing lanes simply lack `owner_session` until their next capture, and readers treat a missing field as unknown.
- **Cleanup/rollback paths:** `pruneBus` (`session-bus-files.mjs:122`) removes expired subscriptions; rollback is a code revert, and an extra `owner_session` field in lane JSON is ignored by the old code.

### Implementation Steps

1. Add the bus-side subscription store, `watch-release` and `notify-release`, with unit tests.
2. Add `owner_session` capture at each executor capture site, with the trust-boundary comment.
3. Add the hint and notify helpers in `release-lane-liveness.sh`, with timeouts and ignored exit codes, then call them from the refusal, finalize and dead-observation paths.
4. Extend the release-lane shell tests using their scratch `AIDEVOPS_STATE_DIR` and a scratch `AIDEVOPS_SESSION_BUS_DIR`.
5. ShellCheck the changed scripts, run every listed test, and record the output in the PR.

### Hazards and Compatibility

- **Concurrency/atomicity:** the field rides on the existing compare-and-swap lane write, so no new race is added; the dead-executor notice uses an exclusive-create marker so concurrent observers send it once.
- **Migration/rollback:** additive JSON field and new bus directory; rollback leaves harmless extra data.
- **Mixed-version/backward compatibility:** older release helpers ignore `owner_session`; an older bus CLI without `notify-release` makes the notify call fail silently.
- **Idempotency/retry:** `release_lane_finalize` is already idempotent for the same receipt (`release-lane-helper.sh:1302-1304`); notify only after the write that changed the state, so a retried finalize does not send twice.
- **Partial failure/recovery:** any hint or notify failure, including a timeout, prints nothing and leaves the release command's exit code and output contract unchanged. The release path must never wait more than the 5 s timeout for the bus.
- **Trust boundary:** `owner_session` is self-reported by the process that captured the executor. It must never authorise reconcile, recovery, abandonment or publication; the executor `host_id`/`pid`/`started_at` observation stays the only liveness authority.

### Files Scope

- `.agents/scripts/release-lane-helper.sh`
- `.agents/scripts/release-lane-liveness.sh`
- `.agents/scripts/full-loop-release-helper.sh`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-release.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/scripts/tests/test-release-lane.sh`
- `.agents/scripts/tests/test-release-lane-liveness.sh`
- `.agents/scripts/setup/modules/agent-deploy.sh`
- `.agents/reference/session-bus.md`
- `.agents/workflows/release.md`

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-release-lane.sh
bash .agents/scripts/tests/test-release-lane-liveness.sh
bash .agents/scripts/tests/test-release-lane-reservation.sh
python3 .agents/scripts/tests/test-release-lane-owner.py
npm test --prefix .agents/plugins/opencode-aidevops
shellcheck .agents/scripts/release-lane-helper.sh .agents/scripts/release-lane-liveness.sh .agents/scripts/full-loop-release-helper.sh
```

- **Runtime evidence (self-test, no owner and no publication):** using the release-lane tests' scratch `AIDEVOPS_STATE_DIR` and a scratch `AIDEVOPS_SESSION_BUS_DIR` with one live `opencode serve` session subscribed by `watch-release`, show each of these:
  - An acquire with `AIDEVOPS_OPENCODE_SESSION_ID` set records `owner_session`.
  - A second acquire prints the owner handle and an `ask` hint.
  - A finalize delivers one `info` notice to the subscriber (visible in `aidevops sessions inbox`).
  - A dead-executor observation sends one notice, and only one across two observations.
  - Every release exit code matches a run with `AIDEVOPS_RELEASE_NOTICES=false`.
- **Surface mapping:** the shell tests cover lane fields, refusal output and exit codes. The plugin tests cover subscriptions and fan-out. The live session covers toast and delivery.
- **Broad verification trigger:** required for release infrastructure. Run the release-lane test set above in full, plus `bash .agents/scripts/tests/test-full-loop-release-helper.sh` and `bash .agents/scripts/tests/test-full-loop-release-reconcile.sh`, which cover the refusal path in `full-loop-release-helper.sh`.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `bash .agents/scripts/tests/test-release-lane.sh`
- [ ] WIP commit created before broad gates: `wip: t18896 release lane session notices`
- [ ] Evidence-triggered broad verification then run: the full release-lane test set

### Scope Boundaries

**Hard boundaries:** no change to who may release, reconcile, recover or publish; no automatic recovery triggered by a notice; no GitHub comments or issue writes; no release, tag or publication during verification; the session bus never wakes a session for a release notice.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] Every executor capture records `owner_session` with a validated session ID, or `null`, and no code path reads it for ownership, recovery or authority (checked by test and by `rg owner_session` showing only write sites, the hint and docs).
- [ ] A release refused because another source holds the lane prints the owner session's handle and live status plus an `aidevops sessions ask` hint; when the owner session is not live it says so.
- [ ] `watch-release <owner/repo>` subscribers and the lane owner session each get one `info` notice when the lane finalizes, and one when an active lane's executor is first observed dead.
- [ ] Release command exit codes and existing output lines are identical with notices on and off.
- [ ] Regression: all listed release-lane tests and the session-bus tests pass.
- [ ] Negative: a lane with a dead executor and an `owner_session` naming a live session is still treated exactly as a dead-executor lane by recovery.

## Relevant Files

- `.agents/scripts/release-lane-helper.sh:44-49,496-500,533-540,597-612,643-644,1292-1325`
- `.agents/scripts/release-lane-liveness.sh:9-60`
- `.agents/scripts/release-lane-owner.py:33,62-80`
- `.agents/scripts/full-loop-release-helper.sh:602-630`
- `.agents/plugins/opencode-aidevops/shell-env.mjs:252-255`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs:17`
