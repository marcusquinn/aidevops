# t18763: worker write fence names the accepted roots

## Origin

- **Created:** 2026-10-23
- **Created by:** ai-interactive
- **Issue:** GH#35495
- **Parent context:** follow-up to GH#35139 (read-wide, write-narrow worker boundary), observed in a managed private repository's imports lane.

## What

Make the headless worker write fence name the roots it actually accepts. When a
worker Write/Edit/patch or mutating Git target falls outside both
`WORKER_WORKTREE_PATH` and the managed temp root, the block message must state
both allowed roots (resolved paths) and say that private or scratch artifacts
belong in an owner-only subdirectory of `AIDEVOPS_TEMP_DIR`. Keep the existing
"Sibling worktrees are read-only for workers" prefix so current callers and
tests keep matching.

## Why

The fence (GH#35139) accepts the worker worktree and `AIDEVOPS_TEMP_DIR`, but
its only message is "Sibling worktrees are read-only for workers. Copy what you
need into your own worktree." Any rejected target, including a private scratch
directory that is not a sibling worktree (for example the sensitive-temp root
`~/.aidevops-private/tmp`), is therefore redirected to the worktree.

Observed on 2026-10-23 in a managed private repository: an imports-batch worker
chose a private scratch directory outside `AIDEVOPS_TEMP_DIR`, the fence
rejected it and pointed to the worktree, and the repository CLI then correctly
refused the Git-ignored worktree cache because batch directories must be
outside Git repositories and inside `AIDEVOPS_TEMP_DIR`. The worker reported
"conflicting artifact-location guards" and exited `BLOCKED`; the terminal
blocker circuit classified it as `permission_required` and held the issue at
`status:blocked`. Both guards already accept the same root, so the blocker was
caused by the fence guidance, not by missing authority. About 20 other batches
of the same brief completed on the same and other runners.

## How

- `.agents/plugins/opencode-aidevops/worker-write-fence.mjs`: build the block
  message from `allowedRoots(env)` so it lists the worker worktree and the
  resolved managed temp root, and directs scratch/private artifacts to a 0700
  subdirectory of `AIDEVOPS_TEMP_DIR`. Apply it to both
  `assertWorkerWritePaths` and `assertWorkerGitTargets`. Keep
  `SIBLING_WORKTREE_MESSAGE` exported as the stable prefix.
- `.agents/plugins/opencode-aidevops/tests/test-git-safety-gate.mjs`: extend the
  existing "headless workers cannot write or run mutating git in sibling
  worktrees" test (around line 1011) to assert the message names
  `AIDEVOPS_TEMP_DIR` and its resolved path.

## Acceptance

- A blocked worker write outside both roots reports the worktree path and the
  resolved `AIDEVOPS_TEMP_DIR` path, plus the scratch-directory guidance.
- Allowed writes (worktree, managed temp) are unchanged.
- `node --test .agents/plugins/opencode-aidevops/tests/test-git-safety-gate.mjs`
  passes.

## Files Scope

- `.agents/plugins/opencode-aidevops/worker-write-fence.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-git-safety-gate.mjs`

## Verification

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-git-safety-gate.mjs
```
