<!-- aidevops:brief-schema=v2 -->
# t18879: Verify Buzz Desktop helper against block/buzz-app Desktop

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `buzz desktop helper opencode acp managed-agents` → 0 hits — no relevant lessons
- [x] Discovery pass: 0 commits / 0 open PRs on target files in last 48h; prior merged work GH#29503, GH#29514, GH#29538, GH#29557, GH#29782
- [x] File refs verified: 6 refs checked, all present at HEAD (`.agents/scripts/buzz-desktop-helper.sh`, `.agents/tests/test-buzz-desktop-helper.sh`, `.agents/bin/opencode-acp`, `.agents/bin/aidevops-buzz-acp`, `.agents/bin/aidevops-buzz-acp-interactive`, `todo/tasks/t18195-brief.md`)
- [x] Tier: `tier:standard` — compatibility boundary decided below; fixture-driven implementation with judgment on detection
- [x] Seeded draft PR decision recorded: skipped — investigation output determines the final diff

## Origin

- **Created:** 2026-11-06
- **Session:** opencode:interactive (block/buzz upstream review)
- **Created by:** ai-interactive
- **Conversation context:** While reviewing block/buzz#5436/#9191, upstream evidence showed Buzz Desktop now ships from `block/buzz-app` (v0.7.0, identifier `xyz.block.buzz.desktop`). `block/buzz` `desktop/` is deprecated (block/buzz#8840). The user asked to capture verification of our Buzz Desktop setup remediation (t18195) against the new app.

## What

Make `aidevops buzz status|apply|reconcile|rollback` and the setup/update reconciliation correct for the new Buzz Desktop from `block/buzz-app`:

1. Detect which Desktop generation is installed at `BUZZ_APP_PATH` by bundle identifier (`CFBundleIdentifier`): legacy `xyz.block.buzz.app` (0.5.x) versus new `xyz.block.buzz.desktop` (0.7+).
2. When the new Desktop is installed, never mutate the legacy store `~/Library/Application Support/xyz.block.buzz.app/agents/managed-agents.json`. The new app reads it only as a one-time "old Buzz" import source (`block/buzz-app` `crates/agent-controller/src/port.rs:186-195`, `crates/agent-controller/src/import.rs:22-25`). `apply`/`reconcile` become successful no-ops, and `status` reports the generation clearly (for example, `Buzz Desktop 0.7.0 (block/buzz-app): legacy remediation not applicable`).
3. Existing private state from a legacy install (`~/.aidevops/state/buzz-opencode-acp-fix.json`) must not trigger reconcile writes once the new Desktop is installed. `rollback` keeps working so an operator can restore legacy records.
4. Record the result of checking whether new-Desktop OpenCode agents still need the `acp` argument workaround, with evidence, in the PR body. If they do, file an upstream `block/buzz-app` issue rather than extending the legacy store mutation.

## Why

The helper is deliberately release-independent (GH#29782). It reconciles the legacy store whenever `/Applications/Buzz.app` exists (`buzz-desktop-helper.sh:344-369`, `:658-680`). The new Desktop keeps the `Buzz` product name, so the same bundle path and `pgrep -x Buzz` check (`:74-81`) match it. As a result, setup/update can rewrite an import-source file that the new app treats as read-only legacy data, and `status` reports misleading counts. Nobody has confirmed the remediation is still needed.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Boundary decided (new Desktop = no legacy writes); the worker must implement identifier detection, adjust command flows, and extend fixtures with judgment about state migration.

## PR Conventions

Leaf task: PR body uses `Resolves #<this issue>`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/buzz-desktop-helper.sh` — add `_buzz_app_identifier()` next to `_buzz_app_version()` (`:56-72`, same `defaults`/`PlistBuddy` pattern plus an `AIDEVOPS_BUZZ_IDENTIFIER_OVERRIDE` test hook); gate `cmd_apply` (`:344`), `cmd_reconcile` (`:658`) and `cmd_status` (`:626`) on the legacy identifier; leave `cmd_rollback` (`:593`) functional.
- EDIT: `.agents/tests/test-buzz-desktop-helper.sh` — fixtures for: new identifier with/without existing state file (no store mutation, byte-identical), status wording, rollback still restoring legacy records, legacy identifier behaviour unchanged.
- EDIT (only if needed): `.agents/bin/opencode-acp` — only if the investigation shows new Desktop launches it; otherwise untouched.

### Complete Write Surface

- **Callers/readers:** `setup.sh` and `aidevops.sh` call the helper's `reconcile`/CLI; no change to callers expected.
- **Writers/mutation paths:** legacy store writes in `_buzz_apply_locked` (`:295-342`), `_buzz_reconcile_managed_locked` (`:532`), `_buzz_write_rollback_store` (`:564`).
- **Existing verification/tests:** `.agents/tests/test-buzz-desktop-helper.sh` (isolated HOME, synthetic records, version/platform/running overrides).
- **Schemas/config:** `BUZZ_STATE_SCHEMA_V2` (`buzz-desktop-helper.sh:26`) and `_buzz_state_schema` (`:407`) stay unchanged — the gate only skips writes, so no state field is added or reinterpreted.
- **Generated/deployed mirrors:** deployed copy under `~/.aidevops/agents/scripts/` via `setup.sh`.
- **Migrations/backfills:** N/A — evidence: new-Desktop installs take the no-op branch before `_buzz_apply_locked`/`_buzz_reconcile_managed_locked`, so no store or state backfill runs; legacy installs keep the existing reconcile path.
- **Cleanup/rollback paths:** `cmd_rollback` (`:593`) and `_buzz_write_rollback_store` (`:564`) unchanged.

### Implementation Steps

1. Add identifier detection with the same fail-closed style as `_buzz_app_version` (symlinked plist → treat as not installed).
2. Unknown identifiers are not legacy: no writes, status says "unrecognised Buzz Desktop identifier".
3. Gate apply/reconcile/status; keep rollback available.
4. Extend fixtures; run the verification below.
5. On a machine with the new Desktop installed, run `aidevops buzz status` and inspect how the new app launches an OpenCode agent (process args via `ps -o args= -p <pid>` while an agent runs). Record whether `acp` is present. Do not print secrets or store contents.

### Hazards and Compatibility

- **Concurrency/atomicity:** unchanged lock/atomic-rename paths; new branch only skips writes.
- **Migration/rollback:** legacy store can hold fallback plaintext credentials; never print it. Rollback must stay usable after upgrading to the new Desktop.
- **Mixed-version/backward compatibility:** legacy 0.5.x behaviour must remain byte-identical in existing tests.
- **Idempotency/retry:** no-op paths are trivially idempotent.
- **Partial failure/recovery:** a failed identifier read means no writes.

### Verification Before Dispatch

```bash
bash .agents/tests/test-buzz-desktop-helper.sh
shellcheck .agents/scripts/buzz-desktop-helper.sh .agents/tests/test-buzz-desktop-helper.sh
.agents/scripts/linters-local.sh --diff
```

- **Surface mapping:** fixtures cover identifier gating, no-mutation, status and rollback; ShellCheck covers shell; diff linter covers repo policy.
- **Broad verification trigger:** none beyond the helper; setup orchestration is not edited.

### Scope Boundaries

**Hard boundaries:** never write the new Desktop's own agent store or keychain entries; never print legacy store contents.

**AI brief owner:** marcusquinn interactive session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/buzz-desktop-helper.sh`
- `.agents/tests/test-buzz-desktop-helper.sh`
- `.agents/bin/opencode-acp`
- `README.md`

## Acceptance Criteria

- [ ] With `CFBundleIdentifier=xyz.block.buzz.desktop`, `apply` and `reconcile` exit 0 and leave the legacy store byte-identical, with or without an existing state file.
- [ ] `status` names the Desktop generation and does not report legacy remediation counts for the new Desktop.
- [ ] `rollback` still restores manifest-owned legacy records when the new Desktop is installed.
- [ ] All existing legacy (`xyz.block.buzz.app`) tests pass unchanged; ShellCheck zero findings; diff linter passes.
- [ ] PR body records whether new-Desktop OpenCode launches include `acp`, with evidence, and links an upstream `block/buzz-app` issue if a workaround is still required.

## Context & Decisions

- Upstream evidence (2026-11-06): `block/buzz-app` `src-tauri/tauri.conf.json` has `productName: Buzz`, `version: 0.7.0`, `identifier: xyz.block.buzz.desktop`; agent credentials service `xyz.block.buzz.desktop.agents` (`crates/agent-controller/src/credentials.rs:16`).
- Rejected: deleting the legacy remediation outright. Users may still run 0.5.x.
- Rejected: porting the mutation to the new app's agent store. It uses keychain-backed harness records, so we should not write it without an upstream contract.

## Relevant Files

- `.agents/scripts/buzz-desktop-helper.sh:56-81,295-369,593-680`
- `.agents/tests/test-buzz-desktop-helper.sh`
- `todo/tasks/t18195-brief.md`

## Dependencies

None.

## Estimate Breakdown

~2h: detection + gating 45m, fixtures 45m, live check and PR 30m.
