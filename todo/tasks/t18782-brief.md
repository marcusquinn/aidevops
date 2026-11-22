# t18782: OpenCode V2: wire DB activity heartbeat and adapt V2 event shape for idle-gated archive

## Origin

- Issue: GH#35898 (interactive session, follow-up to GH#35517)

## What

Wire the GH#35517 OpenCode DB activity heartbeat into the OpenCode 2.x plugin (`v2.mjs`) and teach `db-activity-heartbeat.mjs` the V2 event shape, so the idle-gated archive (v3.39.60) can archive V2-held databases instead of deferring forever.

## Why

GH#35517 / PR #35519 added a per-process busy/idle heartbeat that `opencode-db-archive.sh` requires before touching a held `opencode.db`. The heartbeat is only wired through the V1 entry (`index.mjs:682`, `index.mjs:808`). The V2 entry (`v2-plugin/index.mjs` → `v2.mjs`) never installs it, so any DB held by an `opencode2` process has no heartbeat and the gate fails closed: archive never runs for 24/7 V2 hosts.

Wiring alone is insufficient. Verified against `@opencode/schema@2.2.0` (the pinned `testedVersion` in `.agents/configs/opencode-runtime-profiles.json`):

- V2 events are `{ type, data, created }`, not `{ type, properties }`. `sessionIDFrom()` in `session-turn-state.mjs` reads only `properties`, so every V2 session ID resolves to `""`.
- `session.status` exists (`session-status-event.js`): `data.status.type` is `idle | busy | retry`. `session.idle` exists but is marked deprecated.
- V2 work events are `session.step.*`, `session.tool.*`, `session.text.*`, `session.reasoning.*`, `session.shell.*`, `session.execution.{started,succeeded,failed,interrupted}`, `session.compaction.*`, `session.retry.scheduled`, `permission.asked`, `permission.replied`. None are in the V1 `ACTIVITY_EVENTS` set.

## How (Approach)

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/db-activity-heartbeat.mjs` — read payload from `event.properties || event.data`; resolve session ID from `data.sessionID`; add V2 activity prefixes; map `session.execution.started` → busy and `session.execution.{succeeded,failed,interrupted}` → idle as a fallback to `session.status`.
- EDIT: `.agents/plugins/opencode-aidevops/v2.mjs` — install the heartbeat in `setupAidevopsV2`, feed it from the existing `startEventLoop` handler (same pattern as `index.mjs:808`), and remove the heartbeat file in `disposeAidevopsV2`.
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-db-activity-heartbeat.mjs` — add V2-shaped event cases next to the V1 cases.

### Hazards and Compatibility

- V1 behaviour must not change: V1 events keep the `properties` path.
- Fail closed: any unknown shape must leave busy state unchanged rather than mark idle.
- Do not change `sessionIDFrom()` globally; other V1 consumers rely on it.

### Files Scope

- `.agents/plugins/opencode-aidevops/db-activity-heartbeat.mjs`
- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-db-activity-heartbeat.mjs`

## Acceptance Criteria

- [ ] V2 `session.status` busy/idle events (`{type, data:{sessionID, status:{type}}}`) update `busy_sessions` and list the session ID in the heartbeat file.

  ```yaml
  verify:
    method: bash
    run: "node .agents/plugins/opencode-aidevops/tests/test-db-activity-heartbeat.mjs"
  ```

- [ ] V1 heartbeat behaviour is unchanged (existing V1 cases still pass) and the V2 plugin still loads (`test-opencode-v2-adapter.mjs` passes).

  ```yaml
  verify:
    method: bash
    run: "node .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs"
  ```

## Context & Decisions

- Follow-up to GH#35517 (PR #35519, released v3.39.60). Until this ships, V2-held DBs defer (safe, but never archived).
- Event names were verified from the published `@opencode/schema@2.2.0` package, not inferred from V1.
