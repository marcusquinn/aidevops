<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Machine Migration and Copied Worktrees

Use this guide when you move an aidevops setup to another machine (for example
Intel Mac to Apple Silicon with Migration Assistant), restore a home directory
from backup, or clone a disk, and some original linked worktrees are refused
with:

```text
BLOCKED: lifecycle owner admission unavailable (generation-directory-mismatch)
```

Older releases show the same refusal as `(StoreConflict)`.

## Why it happens

aidevops writes a generation marker into each linked worktree it creates, in
`<repo>/.git/worktrees/<name>/aidevops-generation.json`. The marker records the
installation, the canonical paths and the directory inodes of the worktree and
its Git admin directory. A copy gets new inodes, so the copied marker no longer
matches. Lifecycle state is per machine and is never moved between hosts
(`worker-lifecycle/REGISTRY.md`).

The refusal applies only to agent tools whose workdir or write target is inside
the copied worktree. The files, the index, the branch and its commits are
intact. Plain `git` in a terminal still works, and newly created worktrees work
normally.

## Do not

- Delete or edit markers, reset or delete the lifecycle registry, or set
  `AIDEVOPS_LIFECYCLE_DISABLED=1` to get past the refusal.
- Run `git worktree remove`, `git worktree prune`, `git stash`, `git reset` or
  `git clean` on a copied worktree before its work is rescued and verified.
- Copy the lifecycle registry (`~/.aidevops/.agent-workspace/worker-lifecycle`)
  between machines on purpose. If a migration already copied it, leave it in
  place.

## Path A: the old machine is still available (preferred)

The original worktrees still match their markers on the old machine, so aidevops
works there as normal. Remote access over SSH lets the new machine's agent drive
this.

1. Check that nobody edited the copies on the new machine after migration.
   `git status --short` is not enough: both sides can report the same
   modified file with different contents. Run `worktree-rescue-helper.sh export` (Path B, step 2) for
   the worktree on each machine and compare the `head`, `patch_sha256` and
   `untracked_hashes_sha256` lines of the two `manifest.txt` files. If any differ,
   or you cannot compare them, use Path B for that worktree.
2. On the old machine, for each worktree with uncommitted work, commit it and push
   the branch to its normal remote. Push to a private remote if the work must not
   be public. Alternatively, export a bundle (Path B, step 2) on the old machine
   and copy the bundle directory to the new machine.
3. Do not update aidevops on the old machine until this is done.
4. On the new machine, `git fetch`, then create fresh worktrees from those
   branches with `worktree-helper.sh add <branch>`.

## Path B: rescue on the new machine

`worktree-rescue-helper.sh` copies uncommitted work out of a refused worktree
without modifying it. The source's index and files are checked before and after
the export, and the export refuses if they changed.

1. Inspect the copied worktree, with a workdir outside it (for example the
   canonical repository):

   ```bash
   worktree-rescue-helper.sh inspect /path/to/copied-worktree
   ```

   `git -C /path/to/copied-worktree status|diff|log|show` is also allowed from
   outside it. Commits on the branch are already in the shared repository and
   need no rescue. Only uncommitted files do.

2. Export a bundle. It contains a binary patch of tracked changes (including
   staged, deleted, binary and mode changes), an archive of untracked files, a
   list of ignored files, and checksums. It is written to
   `~/.aidevops/.agent-workspace/work/worktree-rescue/` with mode 0700.

   ```bash
   worktree-rescue-helper.sh export /path/to/copied-worktree
   ```

   It prints `BUNDLE=`, `HEAD=` and `BRANCH=`. The bundle directory must be
   outside the source worktree. Export refuses an untracked nested repository,
   because archiving it would include that repository's `.git` and ignored files.
   Commit and push the nested repository from its own checkout, or copy it by
   hand, then export again.

3. Create a fresh worktree at exactly that commit:

   ```bash
   worktree-helper.sh add rescue/<name> --base <HEAD>
   ```

4. From inside the fresh worktree, import the bundle. The import refuses a
   destination that is not clean or is at a different commit. Afterwards it
   verifies that the tracked diff and every untracked file's hash match the bundle
   exactly, and prints `RESCUE_VERIFIED=` on success.

   ```bash
   worktree-rescue-helper.sh import <BUNDLE>
   ```

5. Ignored files (for example `.env`, local config, `node_modules/`) are listed in
   `<BUNDLE>/ignored.txt` but not copied, because they can hold secrets or be very
   large. Copy any you need by hand, or reinstall dependencies.
6. Commit and push from the fresh worktree as normal. If you retire the copies
   with the guarded path below, retire them first: a commit changes the
   destination HEAD, and guarded retirement refuses a destination that no
   longer matches the rescued HEAD.

`worktree-rescue-helper.sh verify <BUNDLE>` repeats the check at any time. A
successful `verify` (including the one `import` runs) writes
`<BUNDLE>/receipt.txt`, which restates the manifest hashes and pins the manifest
bytes. It is evidence for retirement, never an authorization.

## Interrupted recovery

The source worktree and bundle are never modified, so every step can be
repeated:

- An interrupted export leaves a partial bundle directory. Export again with
  `--out` pointing to a new directory.
- An interrupted import leaves the fresh worktree partly applied, and a second
  import refuses because it is not clean. That worktree holds nothing unique:
  remove it with `worktree-helper.sh remove <path>`, create another at the same
  commit, and import again.
- A failed `verify` means the destination differs from the bundle. Do not
  commit. Recreate the destination and import again.

## After the rescue

Keep the copied worktrees and bundles until the rescued work is checked. Normal
cleanup refuses the copies. The guarded receipt path below requires the verified
destination to remain unchanged at the rescued HEAD until retirement completes.

## Retiring the copies

Do not use `git worktree remove` on a copy: it discards the work without
preservation evidence. Retire it with the guarded path, run from outside the copy:

```bash
python3 ~/.aidevops/agents/worker-lifecycle/worker-registry.py --state-dir <STATE_DIR> \
  retire-foreign-worktree --path <COPY> --repo <owner/repo> --base-branch main \
  --output-root <ARCHIVE_ROOT> --rescue-bundle <BUNDLE>
```

Omit `--rescue-bundle` only for a clean copy whose HEAD is contained in a
remote-tracking ref that `git ls-remote` confirms still points at the same commit
(nothing to rescue; run `git fetch` first if it reports a stale ref). The command:

- re-derives the patch and untracked-file hashes from the copy and refuses unless
  they equal the bundle's, so a copy changed after the rescue is kept; it also
  requires the receipt's rescue destination to still exist at the rescued HEAD;
- repeats this proof immediately before relocation, so a resumed run never relies
  on stale evidence;
- refuses an in-progress merge, rebase, cherry-pick, revert or bisect;
- refuses staged changes, ignored files, and assume-unchanged or skip-worktree
  index flags because Git's normal diff and archive can omit their state. Preserve
  ignored files separately and resolve index state before retrying; verify the
  rescue again afterward;
- archives the copy through the normal WIP archive, verifies it, then has Git
  relocate and remove it with the shared journaled removal; the branch is kept;
- leaves the foreign marker untouched (it is removed only with the whole Git
  administration directory), never opens admission and registers no generation;
- refuses a marker of this installation (use normal cleanup), a generation or path
  already registered here, and a tree that Git does not register at that exact
  path (a copy at a new path shares administration with the original, so it
  cannot be retired this way).

If interrupted after relocation, repeat the command with `--generation-id <ID>`
(the marker's `generation_id`, also printed in an earlier result).

Retirement permanently fences both the foreign generation ID and its original
path in this local registry, including after successful removal. Create fresh
worktrees at a different path: reusing the old directory name cannot distinguish
a new caller from a delayed registration validated before retirement.

For canonical (non-linked) checkouts with unexpected state, use
`reference/dirty-worktree-preservation.md` instead.

## Next time

Before migrating, commit and push or export every worktree with uncommitted
work. After migrating, install aidevops on the new machine and create fresh
worktrees rather than reusing copied ones.
