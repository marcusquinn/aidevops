# Bash FD Locking — Why flock was removed from the pulse instance lock

## Summary

The pulse instance lock uses **mkdir atomicity only**. The supplementary `flock`
layer (FD 9) was removed in GH#18668 after four recurring deadlock incidents.

## Background

`pulse-instance-lock.sh` uses `mkdir "$LOCKDIR"` as the primary atomic lock
primitive (POSIX-guaranteed atomic on APFS, HFS+, ext4, btrfs, xfs). A
supplementary `flock` on FD 9 was added in GH#4513 as a Linux
"belt-and-suspenders" guard — defence-in-depth, not the primary primitive.

## The recurring problem: FD inheritance

Bash has no built-in equivalent of `fcntl(F_SETFD, FD_CLOEXEC)`. When the pulse
opens `exec 9>"$LOCKFILE"` in the parent bash process, FD 9 is inherited by
**every child process** that bash forks — including:

- git commands (`git pull`, `git push`, `git worktree add`, `git rebase`)
- git hooks (pre-commit, post-receive, commit-msg)
- git merge drivers (`bd`, custom merge tools)
- all backgrounded workers

Any of these can daemonise (reparent to PID 1), permanently holding the flock
and deadlocking the next pulse cycle.

## Four failed fix attempts

| Issue | Fix attempted | Why it failed |
|-------|--------------|---------------|
| GH#18094 | `python3 -c "import fcntl; fcntl.fcntl(9, fcntl.F_SETFD, FD_CLOEXEC)"` | `fcntl(F_SETFD)` operates on the calling process's FD table. Running it in a child python3 process only set CLOEXEC on python's copy of FD 9, which was discarded when python exited. The parent bash FD 9 was never modified. |
| GH#18141 | Layer 2 inode self-recovery after 3 bounces | Had a `fuser` parsing bug: `fuser` returned multiple PIDs (orphan + current pulse), `tr -d ' '` concatenated them, `ps -p "298770302558"` failed, `flock_holder_comm` was empty, recovery condition never triggered. |
| GH#18264 | Append `9>&-` to all child-spawning commands | Correct mechanism but blocklist model. 44 uncovered git calls at time of removal. Any new git call without `9>&-` restores the vulnerability. Invisible requirement — nothing in the code communicates it. |
| GH#18668 | This issue | Identified as architectural problem; adopted Path A (remove flock). |

## Why mkdir-only is sufficient

- mkdir is atomic at the kernel level. No TOCTOU race is possible.
- Works on all local filesystems on all platforms — macOS and Linux.
- No utility dependencies (unlike `flock` which requires util-linux on Linux).
- Stale locks from SIGKILL or power loss are handled by PID-file staleness
  detection in `acquire_instance_lock()`.
- The `flock` layer added defence-in-depth against a scenario that mkdir already
  handles: concurrent invocations. Its cost (deadlock risk) exceeded its value.

## Policy

- Do not re-add `flock` or any other persistent-FD locking in pulse scripts.
- If additional concurrency protection is needed, use a separate lock file with
  a short-lived FD (opened and closed within a single function call).
- Reference this document when reviewing PRs that add `exec N>file` patterns
  to pulse orchestration code.
