# t17994 — Fix systemd worker PID handoff fallback race

## Session Origin

Interactive full-loop for GH#23524 after maintainer cryptographic approval. The issue reports that pulse can launch a worker through `systemd-run --user`, fail to read the child pid-file, then fall back to `setsid`/`nohup` while the original transient service worker continues.

## Goal

Make a successful transient systemd launch authoritative unless aidevops proves the unit has no live worker process identity. A missing pid-file is an ambiguous handoff state, not proof that launch failed.

## Scope

- `.agents/scripts/pulse-dispatch-worker-launch.sh`
- `tests/test-systemd-worker-service-launch.sh`
- `TODO.md`
- `todo/tasks/t17994-brief.md`

## Implementation Notes

1. Keep the existing pid-file fast path in `_dlw_exec_systemd_user_service`.
2. When `systemd-run --user` exits successfully but the pid-file remains empty, poll `systemctl --user show <unit> -p MainPID -p ActiveState -p SubState` for a bounded window.
3. If `MainPID` is a positive numeric PID, return it and log that the PID was resolved from the transient unit instead of launching fallback.
4. Only return failure to `_dlw_exec_detached` after the transient unit has no live MainPID or is inactive/failed, preserving legitimate fallback.
5. Keep changes localized; do not broaden dispatch ledger schema in this task.

## Verification

- Run `tests/test-systemd-worker-service-launch.sh`.
- Run ShellCheck or the repository shell linter on changed shell files.
- Confirm the regression test covers both: missing pid-file with systemctl MainPID should not call `setsid`; inactive/no MainPID should allow fallback.

## Privacy

Use only GH#23524 and generic process/unit examples. Do not include private repository names, local usernames, local filesystem paths, or incident-specific issue numbers in public-facing output.
