# t19055: fix(setup): refuse ephemeral OpenCode targets in the Pulse direct shim writer

**Task ID:** `t19055` | **Issue:** GH#38581

## Origin

Interactive session (productivity mission), from tracing the largest recent worker local-error family. On 2026-11-15 between 11:28 and 11:54 UTC, 19 headless worker launches on one host failed with exit 127 before any model work. Each failure excerpt shows the live daemon shim failing at line 9:

```text
~/.local/bin/opencode: line 9: $TMPDIR/tmp.XXXXXXXXXX/.nvm/versions/node/v24.13.1/bin/opencode: No such file or directory
```

GH#38475 / t19031 traced the trigger: Test 14 in `test-resolve-pulse-runtime-binary.sh` called `_pulse_write_direct_opencode_shim` with the caller's real HOME. That replaced the live shim with one pointing at a fixture that was deleted moments later. t19031 made the test hermetic, and t19034 / GH#38481 now pauses a runner after three evidenced runtime-missing launches. Both treated production code as correct.

## What

`_pulse_write_direct_opencode_shim` in `.agents/scripts/setup/modules/schedulers-pulse.sh` is the only one of the three OpenCode shim writers with no ephemeral-target guard. The other two are `_setup_ensure_opencode_stable_shim` in `.agents/scripts/setup/_services.sh` and the one in `.agents/scripts/setup/modules/tool-install.sh`. Both refuse a target under `$TMPDIR`, `/tmp`, `/var/tmp` or `/var/folders/*/*/T/` unless HOME itself is ephemeral. `_resolve_pulse_runtime_binary` makes the gap worse. When the stable-shim writer correctly refuses an ephemeral target, `_pulse_normalize_opencode_binary` returns the raw path. The direct writer then writes it into the live `~/.local/bin/opencode` anyway, and `_persist_pulse_runtime_path` can record the temp path in `~/.config/aidevops/scheduler-runtime-bin`.

Change:

1. `_pulse_write_direct_opencode_shim` returns 1 without writing when the target, or its physical path, is ephemeral and HOME is not. Use `_setup_opencode_binary_is_ephemeral` when it is declared, matching the other writers' `"${HOME}/.aidevops-home"` HOME test.
2. `_pulse_validate_opencode_candidate` rejects the same candidates, so discovery continues to durable installs and a temp path is never shimmed or persisted.

Fixture tests whose HOME is itself ephemeral keep their current behaviour.

## Why

A single misdirected shim write stopped all worker dispatch on the host for 26 minutes. The test fix closed one caller, not the class: any future direct caller, including a setup run with `OPENCODE_BIN` under a temp dir, can repeat the outage. A writer-level guard makes the live shim safe regardless of caller hygiene.

## How (files)

- EDIT `.agents/scripts/setup/modules/schedulers-pulse.sh`: `_pulse_validate_opencode_candidate` (about line 265) and `_pulse_write_direct_opencode_shim` (about line 349). Reference pattern: `_setup_ensure_opencode_stable_shim` in `.agents/scripts/setup/modules/tool-install.sh:1166-1182`.
- EDIT `.agents/scripts/tests/test-resolve-pulse-runtime-binary.sh`: add one case that runs the direct writer with a non-ephemeral HOME and an ephemeral target, and asserts that nothing is written and the result is non-zero.

### Files Scope

- `.agents/scripts/setup/modules/schedulers-pulse.sh`
- `.agents/scripts/tests/test-resolve-pulse-runtime-binary.sh`
- `TODO.md`

## Acceptance

- With a durable HOME and an ephemeral target, `_pulse_write_direct_opencode_shim` returns non-zero and leaves no shim.
- The existing `test-resolve-pulse-runtime-binary.sh`, `test-tool-install-opencode.sh` and `test-setup-opencode-cli.sh` cases still pass.
- ShellCheck is clean on changed shell files.

## Verification

```bash
bash .agents/scripts/tests/test-resolve-pulse-runtime-binary.sh
bash .agents/scripts/tests/test-tool-install-opencode.sh
shellcheck .agents/scripts/setup/modules/schedulers-pulse.sh .agents/scripts/tests/test-resolve-pulse-runtime-binary.sh
```
