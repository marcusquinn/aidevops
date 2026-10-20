## What

Add an on-demand storage cleanup entry point and a default scheduled routine so users never have to discover or wire up the individual cleaners themselves.

- `aidevops cleanup` (no args) prints a dry-run storage report: each aidevops-owned store, its size, and which existing cleaner owns it.
- `aidevops cleanup <tmp|worktrees|opencode|observability> [--apply]` and `aidevops cleanup all [--apply]` run the existing owning cleaners. Dry-run by default.
- New default core routine `r922 Storage hygiene` (daily) runs `storage-cleanup-helper.sh all --apply` through a dedicated launchd/systemd scheduler installed by `setup.sh`, registered as platform-owned in `pulse-routines.sh` so Pulse only runs it as a fallback.
- Existing `branches|remote-branches|local-branches` subcommands are unchanged.

## Why

Session evidence (2026-10-20): the aidevops workspace reached 788 GB and the linked-worktree base 118 GB+ before manual cleanup. The individual cleaners exist (`system-cleanup.sh`, `cleanup-worktrees-async-helper.sh`, `opencode-db-maintenance-helper.sh auto`, `observability-helper.sh retention-maintenance`) but there is no single on-demand entry point, `aidevops cleanup` only handles branches, and tmp cleanup only runs inside Pulse cycles (silently lost when Pulse is disabled).

## How

- NEW: `.agents/scripts/storage-cleanup-helper.sh` — orchestrator only; never deletes directly. Store table: name, sized paths, dry-run command, apply command. Bounded `du` via `timeout_sec`. Commands: `report` (default), `<store> [--apply]`, `all [--apply]`, `help`.
- EDIT: `aidevops.sh` `_main_dispatch_cleanup` — route no-args/`report`/store names/`all` to the helper; keep branch subcommands and help.
- EDIT: `.agents/scripts/routines/core-routines.sh` — add r922 entry + `describe_r922` (model: `describe_r913`).
- EDIT: `.agents/scripts/setup/modules/schedulers-platform.sh` — `setup_storage_hygiene` (model: `setup_opencode_db_archive`).
- EDIT: `setup.sh` — call `setup_storage_hygiene` in interactive and non-interactive scheduler paths.
- EDIT: `.agents/scripts/pulse-routines.sh` `_routine_platform_owned` — `r922:storage-cleanup-helper.sh) name=storage-hygiene`.
- EDIT: docs — `.agents/workflows/worktree-cleanup.md` / `.agents/reference/routines.md` pointer to `aidevops cleanup`.

Out of scope (tracked separately): idle-worktree build artefact reclaim (#35242), storage-inventory coverage/advisories (#35243). The report names these gaps.

## Acceptance

1. `aidevops cleanup` prints a dry-run report with sizes and owning cleaner, deletes nothing.
2. `aidevops cleanup tmp` runs `system-cleanup.sh --dry-run`; with `--apply` runs `--force`.
3. `aidevops cleanup all --apply` runs each store cleaner, continues past individual failures, and exits non-zero if any failed.
4. `aidevops cleanup branches --help` and `local-branches` behave as before.
5. `setup.sh` installs `sh.aidevops.storage-hygiene` (macOS) / `aidevops-storage-hygiene.timer` (Linux).
6. ShellCheck clean on all changed shell files.

## Verification

```bash
shellcheck .agents/scripts/storage-cleanup-helper.sh aidevops.sh .agents/scripts/routines/core-routines.sh .agents/scripts/setup/modules/schedulers-platform.sh .agents/scripts/pulse-routines.sh
bash aidevops.sh cleanup
bash .agents/scripts/storage-cleanup-helper.sh tmp
bash .agents/scripts/tests/test-pulse-routines-selector.sh
```

## Files Scope

- .agents/scripts/storage-cleanup-helper.sh
- aidevops.sh
- .agents/scripts/routines/core-routines.sh
- .agents/scripts/setup/modules/schedulers-platform.sh
- setup.sh
- .agents/scripts/pulse-routines.sh
- .agents/workflows/worktree-cleanup.md
- .agents/reference/routines.md
