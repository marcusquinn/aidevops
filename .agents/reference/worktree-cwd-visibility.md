# Protected Linux process CWDs during worktree cleanup

The worktree removal guard must prove that no live process has its working
directory inside the candidate. On Linux, same-user `gpg-agent`, `sshd`, and
`sd-pam` processes can deny unprivileged `/proc/<pid>/cwd` reads. Their name,
parent, or apparent daemon role is not proof of their working directory. The
guard therefore fails closed with `cwd-visibility-degraded`.

To see which processes currently cause this, run
`worktree-helper.sh recovery unreadable-processes`. It lists the PID, `comm`
and remedy of each process that still blocks visibility after the inspector
below has been tried. The remedy is `inspector` when the inspector's UID rule
accepts the process, so installing or repairing the inspector clears it, and
`stop-only` when only stopping the process through its normal controls clears
it. The listing is read-only and is for manual review only.

## Unprivileged NixOS adapter

On Linux with exact `ID=nixos` in `/etc/os-release`, process observation does
not invoke the privileged inspector. Selection is automatic with no opt-in flag.
The release file is parsed as data, never sourced as shell code. Other Linux
systems and macOS retain their existing observation paths.

The diagnostic reports `unprivileged-review` on NixOS. This does not prove that
a denied process is idle or unrelated. Readable CWD matches still block cleanup,
and unreadable same-user processes still produce degraded evidence. Existing
candidate-local lease, Git, terminal-PR and archive checks remain authoritative;
this adapter alone does not fix archive failures or authorize permanent removal.
Do not stop login/session services merely to silence the diagnostic.

Implementation boundaries:

- `scripts/worktree-process-policy.sh`: platform selection and inspector policy.
- `scripts/worktree-process-providers.sh`: shared procfs/lsof observation adapters.
- `scripts/worktree_process_proc.py`: Linux procfs collector using only Python
  stdlib, without per-process subprocesses; initially selected only on NixOS.
- `scripts/audit-worktree-removal-helper.sh`: identity, ownership and removal guards.

Providers retain the existing stdout and exit-status contract: readable CWDs,
with status 0 for complete, 2 for degraded, and 1 for unusable evidence. Future
platform adapters must preserve uncertainty and positive matches rather than
duplicating or weakening removal policy. The modules are sourced through the
audit helper, not standalone cleanup commands.

Verification: `bash .agents/scripts/tests/test-worktree-removal-audit.sh`;
on non-FHS hosts set `AIDEVOPS_TEST_GIT_BIN` to the installed real Git executable.
Run the isolated suite with native Git first on its subprocess PATH: the agent's
Git shim can reject the suite's temporary race-injection wrappers before they
exercise late-lock protection. Do not change the interactive session's Git guard.
Run `worktree-helper.sh recovery unreadable-processes` for read-only host evidence.

The local verification matrix is native NixOS plus an unprivileged Ubuntu 26.04
LTS container. Install `python3`, `git`, `jq`, `lsof` and `sqlite3` in the disposable
container, mount the scripts read-only, and run the suite as a non-root user with
a disposable HOME. SQLite is required for the live lease test. This checks Ubuntu
userspace portability, not a separate kernel or a real macOS host. Do not add a
CI/CD matrix or change the other platforms' runtime selection for this rollout.

### Recovery reservation failures are separate from process visibility

On NixOS, a failed reservation emits `recovery-reservation-unavailable` with
`stage=reserve` in the cleanup audit log, before the existing aggregate archive
failure. This distinguishes an archive prerequisite from an actual copy failure.
External deletion of archive directories can leave retained attempt records
pointing to missing buckets. Process observation cannot resolve that storage state.

An existing `.archive-attempt-*.json` is not disposable cache. A missing bucket
fails validation with `archive bucket unavailable`; repeated cleanup cannot
repair it by waiting. Preserve the source and reservation, inspect historical
removal/retention evidence, and obtain an explicit recovery decision before
replacing an attempt. Do not silently reset reservations, recreate completion
markers, or claim that a newly captured source restores missing historical data.
The isolated archive-copy test covers this case and verifies that the reservation
and source remain intact without allocating another bucket.

Any operator-authorized one-time removal of stale records must use the existing
producer lock, validate record schema and identity-derived filename, and confirm
that the referenced direct-child bucket is absent immediately before mutation.
Permission errors and dangling symlinks are not absence. Retention transaction
state needs separate review. Preserve records for existing buckets and do not
delete source worktrees or create new snapshots as a side effect. This adapter
does not add automatic reservation repair or a new recovery command.

Recovery stores and their PID-based producer locks are **host-local**. Multiple
pulse hosts must use separate local stores/worktrees; sharing the recovery root
over NFS is not supported by this change. Cross-host task claims are a separate
boundary (see `cross-runner-coordination.md`); local process absence never proves
that a task on another host is inactive. GitHub App authentication is separate
work and is not introduced here.

## Optional privileged read-only inspector

`.agents/scripts/worktree-cwd-inspect.py` reads **one** process CWD. It accepts
only a numeric PID whose real UID is the invoking `SUDO_UID` and whose
effective, saved and filesystem UIDs are each that user or root (`0`). The root
allowance covers same-user setuid-root helpers, such as a FUSE mount's
`fusermount3 auto_unmount` watcher or an open `sudo` parent, which keep root
privileges but were started by the user
(GH#32871). Any other UID, including a root real UID, is another identity and
is refused. It verifies that the process identity remains stable during the
read, rejects control-character/non-absolute output, and neither edits files nor
authorizes deletion. The ordinary guard still checks the candidate, Git
registration/locks, ownership, process CWDs, and recovery requirements.

This is an **opt-in operator installation**, not part of automatic setup:

1. Review the inspector from a trusted release. Copy it to
   `/usr/local/libexec/aidevops-worktree-cwd-inspect` as root, with root
   ownership and mode `0755`. Ensure the executable **and every parent
   directory** cannot be replaced or written by the cleanup user; never grant
   sudo access to a script inside a writable Git checkout. Line 1 must name an
   absolute, root-owned `python3 -I` (never `/usr/bin/env`, which would follow
   the caller's PATH under sudo). If the host has no `/usr/bin/python3`, set it
   to `realpath "$(command -v python3)"` after confirming that file and its
   parent directories are root-owned and not group/other writable.
2. Using `visudo`, allow only the dedicated executable as root with
   `NOPASSWD`, restricted to the intended local user. Example sudoers entry
   (replace `operator` with that user):

   ```text
   operator ALL=(root) NOPASSWD: /usr/local/libexec/aidevops-worktree-cwd-inspect
   ```

   With no argument list, both sudo.ws and sudo-rs allow any arguments; the
   executable is the argument validator. It requires exactly one
   `[1-9][0-9]*` PID and refuses cross-user process reads. Do not add an
   argument pattern such as `[1-9]*`: sudo-rs (the default `sudo` on Ubuntu
   25.10+ and 26.04 LTS) rejects wildcards in command arguments and ignores
   the whole line, and sudo.ws wildcards match more than digits anyway (GH#34621).
   Do not use `""` either, which permits no arguments. Do not grant a generic
   `readlink`, shell, Python interpreter, or broad sudo command instead. Keep
   `SUDO_UID` managed by sudo, not caller-provided.

   Validate the file with the target host's own implementation before relying
   on it: `visudo -c -f <file>` must report it parsed OK with no warnings.
   `sudo --version` names `sudo-rs` when that implementation is active (on
   Ubuntu, `readlink -f /etc/alternatives/sudo` also resolves to
   `/usr/lib/cargo/bin/sudo`).
3. Verify an authorized protected same-user PID via
   `sudo -n -- /usr/local/libexec/aidevops-worktree-cwd-inspect <pid>` and
   verify a foreign PID fails. Avoid sharing CWD output if it contains private
   paths. Retry the **normal guarded remover**, not `git worktree remove
   --force` or direct filesystem deletion.

The guard invokes the inspector only after a normal CWD read fails and the
process cannot be proved foreign or zombie. Uninstalled, rejected, timed-out,
or empty privileged reads retain `cwd-visibility-degraded`. No global `/proc`
permission or ptrace setting changes are needed. Revoke the sudoers rule and
remove the installed copy when privileged inspection is no longer needed.
