## Origin

- **Created:** 2026-10-06, interactive throughput review (maintainer session)
- **Evidence source:** live `~/.aidevops/logs/pulse.log`, local repo configs, `runner-capability-helper.sh`

## What

Stop a malformed repo-local `.aidevops.json` from silently starving every dispatch
candidate in that repository. The runner-capability gate must (1) not parse the repo
config at all when the issue has no `dispatch-class:` label, and (2) when it does need
the config and cannot parse it, report a distinct, non-cooldown signal
(`config_unreadable path=.aidevops.json`) instead of the generic `invalid_requirements`.

## Why

Throughput: on this runner, every available issue in two pulse-enabled repos is blocked
for 6 hours at a time, indefinitely, with a misleading reason.

- Five issues in `<private-managed-repo>` and `marcusquinn/cloudron-netbird-app` #158 #165 —
  all `status:available` + `auto-dispatch`, unassigned, no `dispatch-class:` labels, no `requires-*` body lines.
- Pulse log, repeating since at least line 295623:
  `Dispatch_max: #N (<private-managed-repo>) runner_capability_unmet cooldown recorded signal=invalid_requirements ttl=21600s`
  then `Dispatch enumeration: <private-managed-repo> runner_capability_unmet cooldown skipped #N ...` (five issues).
- Both repos' `.aidevops.json` are invalid JSON (an extra `}` closes the root object before `"plugins": []`):
  Python `json.loads` → `Extra data: line 34 column 4`.
- Mechanism: `.agents/scripts/runner-capability-helper.sh:193` parses config unconditionally;
  `json.JSONDecodeError` is a `ValueError`, caught at line 279 → bare `unmet()` → shell maps a
  reason-less verdict to `signal=invalid_requirements` (lines 56-57) → `cooldown=eligible` (line 63)
  → 6 h cooldown recorded by `_dispatch_capability_cooldown_record` (`pulse-dispatch-lib-candidates.sh:994`).
- Scan of this runner's pulse repos: 11 valid configs, 2 malformed, 41 without a config.

## Tier

`tier:standard` — small, well-located change in one helper plus focused test cases in its existing suite.

## How (Approach)

### Worker Quick-Start

- `.agents/scripts/runner-capability-helper.sh:185-281` — embedded Python requirements check.
- `.agents/scripts/runner-capability-helper.sh:44-68` — shell signal/cooldown mapping.
- `.agents/scripts/pulse-dispatch-lib-candidates.sh:965-1079` — cooldown fingerprint includes a config fingerprint, so a repaired file already clears the cooldown; no change needed there.
- Existing suite: `.agents/scripts/tests/test-runner-capability.sh`.

### Files to Modify

- `EDIT: .agents/scripts/runner-capability-helper.sh:187-204` — collect `dispatch-class:` labels first; read/parse `.aidevops.json` only when at least one is present. On parse failure call `unmet('config_unreadable path=.aidevops.json')`.
- `EDIT: .agents/scripts/runner-capability-helper.sh:53-64` — leave `config_unreadable` out of the cooldown-eligible set (operator-fixable, cheap to re-check; fingerprint changes on repair anyway). Keep bare-verdict mapping unchanged otherwise.
- `EDIT: .agents/scripts/tests/test-runner-capability.sh` — add cases below to the existing suite (no new harness).

### Complete Write Surface

- **Callers/readers:** `runner_capability_check` is called from the `dispatch_with_dedup` path via `_runner_capability_*` wrapper at `runner-capability-helper.sh:20-37`; cooldown consumers in `pulse-dispatch-lib-candidates.sh` parse only the `signal=` and `cooldown=` fields.
- **Writers/mutation paths:** none beyond log lines and the existing cooldown file (not written for the new signal).
- **Existing verification/tests:** `tests/test-runner-capability.sh`; `tests/test-pulse-wrapper-worker-detection.sh` and `tests/test-dispatch-max-parallel.sh` stub ranked candidates and should stay green.
- **Schemas/config:** none.
- **Generated/deployed mirrors:** deployed copy via `setup.sh`; no generated output.
- **Migrations/backfills:** none; existing cooldown files keyed on the old fingerprint expire or are invalidated on config repair.
- **Cleanup/rollback paths:** code revert only.

### Implementation Steps

1. In the Python block, compute `class_names = [label[len('dispatch-class:'):] ...]` from issue labels before touching config. If empty, set `classes = {}` and skip reading `.aidevops.json` (symlink check included).
2. When `class_names` is non-empty, read and parse the config inside a narrow `try`; on `ValueError`/`OSError` call `unmet('config_unreadable path=.aidevops.json')`.
3. In `_runner_capability_log_deferral`, the existing `reason=([a-z_]+)` extraction yields `signal=config_unreadable`; confirm it is NOT in the `cooldown=eligible` case list.
4. Add test cases; run verification.

### Hazards and Compatibility

- **Concurrency/atomicity:** read-only check; no new shared state.
- **Migration/rollback:** none; behaviour for valid configs and labelled issues unchanged.
- **Mixed-version/backward compatibility:** older runners keep the 6 h cooldown; newer runners dispatch unlabelled issues regardless of config validity.
- **Idempotency/retry:** `config_unreadable` re-checks every cycle (cheap file parse).
- **Partial failure/recovery:** an unparseable config still blocks only issues that genuinely need class requirements, with an actionable reason.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-runner-capability.sh
shellcheck .agents/scripts/runner-capability-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** suite proves both acceptance paths and the unchanged valid-config path; shellcheck/linters cover the shell wrapper.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not change secret, probe, or SSH requirement handling; do not repair other repositories' `.aidevops.json` files in this PR (separate operator action).

**AI brief owner:** interactive maintainer session that filed this issue.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/runner-capability-helper.sh`
- `.agents/scripts/tests/test-runner-capability.sh`

## Acceptance Criteria

- [ ] Positive: an issue with no `dispatch-class:` label in a repo whose `.aidevops.json` is malformed passes `runner_capability_check` (exit 0).
- [ ] Positive: an issue with a `dispatch-class:` label in a repo with malformed `.aidevops.json` fails with `runner_capability_unmet reason=config_unreadable path=.aidevops.json`, logged as `signal=config_unreadable cooldown=none`.
- [ ] Regression: valid config + `dispatch-class:` label with an unmet secret/probe still yields the existing signals and cooldown eligibility.
- [ ] All verification commands pass.

## Context & Decisions

- Chosen: skip config parsing when no class label requests it — the config is only consulted for `dispatch_class_requirements`, so validity is irrelevant otherwise.
- Rejected: auto-repairing malformed `.aidevops.json` from the dispatch path — writes to canonical checkouts belong to the audited project-config migration path (`repo-aidevops-health-helper.sh`), not dispatch.
- Follow-up candidate (not this task): `repo-aidevops-health-helper.sh` could report malformed `.aidevops.json` in its health output.

## Relevant Files

- `.agents/scripts/runner-capability-helper.sh:44-68,185-281`
- `.agents/scripts/pulse-dispatch-lib-candidates.sh:965-1079`
- `.agents/scripts/tests/test-runner-capability.sh`
