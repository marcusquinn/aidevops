<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18529: opt-in CWD inspector reads same-user setuid-root helpers; advisory names the diagnostic

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive (maintainer review of GH#32871)
- **Parent task:** none
- **Conversation context:** GH#32871 reports that recovery maintenance still reclaims 0 bytes on Ubuntu 24.04 desktops after #32846. Five same-user, non-dumpable processes (`systemd --user`, `(sd-pam)`, `gpg-agent`, `ssh-agent`, `fusermount3`) keep process visibility degraded. The maintainer review ([comment](https://github.com/marcusquinn/aidevops/issues/32871#issuecomment-5878377934)) declined relaxing the fail-closed evidence rule, and noted that the persistent advisory already exists. It found a real defect: the documented remedy, the opt-in root inspector, cannot clear mixed-UID same-user processes.

## What

The opt-in inspector and the removal guard agree on one rule: a process is inspectable when its real UID is the caller and every other `Uid:` field is the caller or `0`. The `unreadable-processes` diagnostic says, for each entry, whether the inspector can clear it. The recovery advisory names the diagnostic command.

## Why

`worktree-cwd-inspect.py:18` rejects any process whose four `Uid:` fields differ. `_worktree_proc_entry_is_provably_foreign_uid` (`audit-worktree-removal-helper.sh:179-185`) treats a process as foreign only when all four differ. A setuid-root helper started by the user (ruid = user, euid/suid = 0) is therefore neither foreign nor inspectable. Examples are the `fusermount3 auto_unmount` watcher (libfuse `util/fusermount.c:1886-1887`: `setsid(); chdir("/")`, keeps root to unmount) and any open `sudo` parent. On stock GNOME desktops, degraded visibility cannot be cleared even after the operator completes the documented sudoers opt-in.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/worktree-cwd-inspect.py:13-39` — replace `owner_uid()` with a pure `uid_fields_accepted(values, sudo_uid) -> bool` (4 numeric fields, `values[0] == sudo_uid`, rest in `{sudo_uid, 0}`) and a `/proc` reader that uses it before and after the `readlink`.
- `EDIT: .agents/scripts/audit-worktree-removal-helper.sh:160-188` — add `_worktree_proc_entry_is_inspectable_uid <proc_dir> <current_uid>` with the same rule (reads `status` `Uid:`; returns 1 when unreadable).
- `EDIT: .agents/scripts/audit-worktree-removal-helper.sh:343-374` — `list_worktree_unreadable_proc_cwds` emits `<pid>\t<comm>\t<remedy>`, where `<remedy>` is `inspector` or `stop-only`.
- `EDIT: .agents/scripts/worktree-recovery-lifecycle-helper.sh:1523` — header gains the REMEDY column.
- `EDIT: .agents/scripts/worktree-recovery-maintenance-helper.sh:1468` — advisory line names `worktree-helper.sh recovery unreadable-processes`.
- `EDIT: .agents/reference/worktree-cwd-visibility.md` and `.agents/reference/storage-lifecycle-worktree-recovery.md:314-318` — document the UID rule, the remedy column, and the `fusermount3`/`sudo` examples.
- `EDIT: .agents/scripts/tests/test-worktree-recovery-lifecycle.sh:2791-2839` — fixture supports explicit UID fields; the listing covers `inspector`/`stop-only`; the advisory text includes the diagnostic command.
- `EDIT: .agents/scripts/tests/test-worktree-removal-audit-lib.sh` — the Python `uid_fields_accepted` accepts `u u u u` and `u 0 0 0`/`u 0 0 u`, and rejects `u v v v`, `0 u u u`, `u u u v`, malformed, and wrong-length input.

### Complete Write Surface

- **Callers/readers:** `_capture_worktree_proc_cwds` and `list_worktree_unreadable_proc_cwds` call `_worktree_privileged_read_cwd`. `worktree-helper.sh recovery unreadable-processes` passes through to the lifecycle helper. `rg -n "list_worktree_unreadable_proc_cwds|aidevops-worktree-cwd-inspect|_worktree_privileged_read_cwd" .agents/` lists all uses.
- **Writers/mutation paths:** `worktree-recovery-maintenance-helper.sh:1440-1479` rewrites the `~/.aidevops/advisories/worktree-recovery-retention.advisory` text. The inspector and diagnostic stay read-only.
- **Existing verification/tests:** `.agents/scripts/tests/test-worktree-removal-audit-lib.sh`, `.agents/scripts/tests/test-worktree-recovery-lifecycle.sh`.
- **Schemas/config:** N/A because no JSON schema or config key changes; the diagnostic is human-readable terminal output.
- **Generated/deployed mirrors:** `~/.aidevops/agents/scripts/` via `setup.sh`. Operators who installed `/usr/local/libexec/aidevops-worktree-cwd-inspect` must reinstall it from the release.
- **Migrations/backfills:** N/A because no persisted state changes.
- **Cleanup/rollback paths:** `git revert` of the PR. An older installed inspector keeps the stricter rule, which only fails closed.

### Implementation Steps

1. In `worktree-cwd-inspect.py`, add `uid_fields_accepted(values, sudo_uid)` and use it in both identity reads. Keep every other check.
2. In `audit-worktree-removal-helper.sh`, add `_worktree_proc_entry_is_inspectable_uid` mirroring the Python rule, and use it in `list_worktree_unreadable_proc_cwds` to emit the remedy column.
3. Update the lifecycle diagnostic header, the maintenance advisory line, and both reference docs.
4. Extend the fixture helper to accept explicit `Uid:` fields. Add listing and advisory assertions, and a Python rule test that imports the inspector by path.

### Hazards and Compatibility

- **Concurrency/atomicity:** the inspector keeps its before/after `/proc/<pid>` inode and UID recheck, so a PID reused mid-read still fails closed.
- **Migration/rollback:** N/A because there is no persisted state; a revert restores the stricter rule.
- **Mixed-version/backward compatibility:** an older installed inspector keeps rejecting mixed UIDs (fails closed), and the bash rule only labels diagnostics. Security boundary: the root inspector will now disclose the CWD path of setuid-root processes whose real UID is the caller. Only the path is disclosed, only to that user; `SUDO_UID` stays sudo-managed and non-zero.
- **Idempotency/retry:** the probes are read-only, so repeated runs give the same answer for an unchanged process table.
- **Partial failure/recovery:** any inspector failure, timeout or malformed output keeps `cwd-visibility-degraded`. Deletion authority is unchanged, because extra visibility only adds blocking matches.

### Complexity Impact

- **Target function:** `list_worktree_unreadable_proc_cwds` (32 lines, threshold 100). It grows by about 4 lines. No action required.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-worktree-removal-audit-lib.sh
bash .agents/scripts/tests/test-worktree-recovery-lifecycle.sh
shellcheck .agents/scripts/audit-worktree-removal-helper.sh .agents/scripts/worktree-recovery-lifecycle-helper.sh .agents/scripts/worktree-recovery-maintenance-helper.sh
python3 -m py_compile .agents/scripts/worktree-cwd-inspect.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the removal-audit test covers the inspector rule; the lifecycle test covers the diagnostic and the advisory; ShellCheck and py_compile cover syntax.
- **Broad verification trigger:** Not required.

### Files Scope

- .agents/scripts/worktree-cwd-inspect.py
- .agents/scripts/audit-worktree-removal-helper.sh
- .agents/scripts/worktree-recovery-lifecycle-helper.sh
- .agents/scripts/worktree-recovery-maintenance-helper.sh
- .agents/reference/worktree-cwd-visibility.md
- .agents/reference/storage-lifecycle-worktree-recovery.md
- .agents/scripts/tests/test-worktree-recovery-lifecycle.sh
- .agents/scripts/tests/test-worktree-removal-audit-lib.sh
- todo/tasks/t18529-brief.md
- TODO.md

## Acceptance Criteria

- [ ] The inspector accepts `Uid: u u u u`, `u 0 0 0` and `u 0 0 u` for caller `u`, and rejects any other mix, including a real UID of 0.
- [ ] `unreadable-processes` labels each entry `inspector` or `stop-only` by the same rule.
- [ ] The recovery advisory names `worktree-helper.sh recovery unreadable-processes`.
- [ ] Degraded-visibility semantics and deletion authority are unchanged. Existing tests pass.
