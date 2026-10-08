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
   operator ALL=(root) NOPASSWD: /usr/local/libexec/aidevops-worktree-cwd-inspect [1-9]*
   ```

   Sudoers wildcards can match more than digits; the executable independently
   rejects extra or malformed arguments and refuses cross-user process reads.
   Do not grant a generic `readlink`, shell, Python interpreter, or broad sudo
   command instead. Keep `SUDO_UID` managed by sudo, not caller-provided.
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
