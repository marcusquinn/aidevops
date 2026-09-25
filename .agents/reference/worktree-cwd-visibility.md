# Protected Linux process CWDs during worktree cleanup

The worktree removal guard must prove that no live process has its working
directory inside the candidate. On Linux, same-user `gpg-agent`, `sshd`, and
`sd-pam` processes can deny unprivileged `/proc/<pid>/cwd` reads. Their name,
parent, or apparent daemon role is not proof of their working directory. The
guard therefore fails closed with `cwd-visibility-degraded`.

## Optional privileged read-only inspector

`.agents/scripts/worktree-cwd-inspect.py` reads **one** process CWD. It accepts
only a numeric PID whose four Linux process UID fields match the invoking
`SUDO_UID`. It verifies that the process identity remains stable during the
read, rejects control-character/non-absolute output, and neither edits files nor
authorizes deletion. The ordinary guard still checks the candidate, Git
registration/locks, ownership, process CWDs, and recovery requirements.

This is an **opt-in operator installation**, not part of automatic setup:

1. Review the inspector from a trusted release. Copy it to
   `/usr/local/libexec/aidevops-worktree-cwd-inspect` as root, with root
   ownership and mode `0755`. Ensure the executable **and every parent
   directory** cannot be replaced or written by the cleanup user; never grant
   sudo access to a script inside a writable Git checkout.
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
