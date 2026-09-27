---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18491: fix: session worktree resolver errors say 'Image workdir' for bounded operations and hide which root failed

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `Image workdir bounded operation` → 0 hits
- [x] Discovery pass: open issues searched for "Image workdir" → none
- [x] File refs verified:
  - `.agents/plugins/opencode-aidevops/gpt-image-worktree.mjs` (92 lines): `gitPath` at :12, `gitWorktreeIdentity` at :26, `resolveSessionOwnedWorktreeRoot` at :49
  - `.agents/plugins/opencode-aidevops/bounded-interactive-operation.mjs:59-68` passes `subject: "Operation"`
  - `.agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs:182` asserts that subject
- [x] Tier: `tier:simple`, a message-only change in one function pair

## Origin

- **Created:** 2026-09-27
- **Created by:** ai-interactive
- **Issue:** GH#32612
- **Conversation context:** `aidevops_bounded_operation start` with a `cwd` in the agent workspace returned `{"schema":"aidevops.interactive-operation/v1","error":"Image workdir must be an existing Git worktree root."}`. The session had started in a plain folder that holds several repositories, which is not itself a Git worktree. The message named images, and did not say that the startup root was the failing path.

## What

Worktree-resolver errors should use the caller's `subject` ("Operation" or "Image") and say whether the session project root or the requested workdir is the path that is not a Git worktree root.

## Why

The wrong noun ("Image" for an unrelated command-runner tool) and the missing path role send users and agents to the wrong fix. In this session the agent fell back to running commands directly because the real cause was not visible.

## Tier

### Tier checklist (verify before assigning)

- [x] **Exact execution contract supplied?**
- [x] **Targets and reference pattern verified?**
- [x] **No semantic or design decision remains?**
- [x] **Bounded, reversible, low-consequence impact?** Only message text changes; the checks are unchanged.
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:simple`

**Tier rationale:** Two private functions gain a `subject` parameter and a role label. No control flow changes.

## PR Conventions

Leaf task: the PR uses `Resolves #32612`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/gpt-image-worktree.mjs:12-33`: `gitPath(root, argument, subject, role)` and `gitWorktreeIdentity(root, subject, role)`. Update the call sites at :73 and :74 to pass `subject` and the role (`"session project root"` or `"requested workdir"`).
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs`: add one case where the startup root is a non-Git temporary directory. Assert that the error starts with `Operation workdir` and names the session project root.

### Complete Write Surface

- **Callers/readers:** `gpt-image-tool.mjs` through `resolveGptImageProjectRoot` (subject "Image"), and `bounded-interactive-operation.mjs:62` through `resolveSessionOwnedWorktreeRoot` (subject "Operation").
- **Writers/mutation paths:** none; the resolver is read-only (`git rev-parse` and `realpath`).
- **Existing verification/tests:** `tests/test-bounded-interactive-operation.mjs` and `tests/test-gpt-image-tool.mjs` exercise resolution with injected resolvers.
- **Schemas/config:** N/A, because error strings are not persisted or parsed; the tool result is `{schema, error}`, with `error` as free text.
- **Generated/deployed mirrors:** `setup.sh` deploys the plugin into the OpenCode plugin directory; no build step.
- **Migrations/backfills:** N/A because the resolver keeps no stored state.
- **Cleanup/rollback paths:** `git revert` of the PR commit restores the old messages.

### Implementation Steps

1. In `gitPath`, change the catch to throw a template-literal error reading `<subject> workdir: the <role> is not an existing Git worktree root.`, interpolating `subject` and `role`. Default `subject` to `"Image"` and `role` to `"requested workdir"`, so any other caller keeps the same wording.
2. In `gitWorktreeIdentity`, pass `subject` and `role` through, and use `${subject}` in the "must name the Git worktree root" message.
3. In `resolveSessionOwnedWorktreeRoot`, call with `(startupRoot, subject, "session project root")` and `(root, subject, "requested workdir")`.
4. Add the test case, then run both plugin tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A; pure read-only resolution.
- **Migration/rollback:** a revert restores the old text.
- **Mixed-version/backward compatibility:** no consumer parses these strings. Existing test assertions are updated in the same PR.
- **Idempotency/retry:** unchanged.
- **Partial failure/recovery:** unchanged; failures still throw before any spawn.

### Verification Before Dispatch

```bash
node .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs
node .agents/plugins/opencode-aidevops/tests/test-gpt-image-tool.mjs
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the bounded-operation test proves the Operation wording and role. The image test proves the Image wording and that inputs are still rejected. The linter covers style.
- **Broad verification trigger:** not required.

### Scope Boundaries

**Hard boundaries:** do not relax worktree ownership, linked-worktree or confinement checks; only message text and parameters change.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/plugins/opencode-aidevops/gpt-image-worktree.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs`
- `TODO.md`
- `todo/tasks/t18491-brief.md`

## Acceptance Criteria

- [ ] With subject `Operation` and a non-Git startup root, the error starts with `Operation workdir` and names the session project root.

  ```yaml
  verify:
    method: bash
    run: "node .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs"
  ```

- [ ] Regression guard: `gpt_image_generate` keeps `Image workdir …` wording, and every previously rejected input is still rejected.

  ```yaml
  verify:
    method: bash
    run: "node .agents/plugins/opencode-aidevops/tests/test-gpt-image-tool.mjs"
  ```

## Context & Decisions

- Out of scope: whether bounded operations should also accept the aidevops agent workspace as a confined `cwd`. That is a confinement policy decision; file it separately if wanted.

## Relevant Files

- `.agents/plugins/opencode-aidevops/gpt-image-worktree.mjs:12` — `gitPath`.
- `.agents/plugins/opencode-aidevops/bounded-interactive-operation.mjs:59` — `resolveCwd`.

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | one file |
| Implementation | 15m | parameters and messages |
| Verification | 10m | two tests |
| **Total** | **~30m** | |
