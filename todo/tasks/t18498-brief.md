<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18498: Get code diagnostics from project lint, typecheck, or compiler commands, not LSP

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `opencode 2 v2 compatibility sidebar lsp todo` → 0 hits — no relevant lessons
- [x] Discovery pass: 0 open PRs touch the three target files for LSP guidance; related open issues are #32645 (V2 todo/catalogue parity), #32619 and #32647 (other V2 gaps)
- [x] File refs verified: 3 refs checked, all present at HEAD `5a2a4dc46`
- [x] Tier: `tier:simple` — three exact documentation insertions, no design choice left
- [x] Seeded draft PR decision recorded: skipped — the exact edits below are the whole change

## Origin

- **Created:** 2026-09-28
- **Session:** opencode:ses_f1ae20a63ffeFJycVVOT3WXoWq
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** While checking aidevops parity with OpenCode 2, we found that V2 no longer runs language servers. The maintainer decision was to follow upstream's direction and state that code diagnostics come from the project's lint, typecheck, or compiler commands.

## What

Framework guidance says plainly that code diagnostics come from the project's own lint, typecheck, or compiler commands, not from LSP. The OpenCode reference documents the LSP status of each runtime, so agents and users know that V2 has no LSP and that this is expected.

## Why

The OpenCode 2 migration guide (`services/www/src/docs/content/migrate-v1.mdx:415` on the `v2` branch of anomalyco/opencode) says:

> "V2 accepts and preserves `lsp` configuration, but it does not run language servers, expose LSP tools, or produce LSP diagnostics. Replace workflows that depend on those capabilities with the project's lint, typecheck, or compiler commands."

This was verified with `gh api repos/anomalyco/opencode/contents/services/www/src/docs/content/migrate-v1.mdx?ref=v2`. The installed 2.0.3 binary has no `sidebar-lsp` panel, while V1 1.18.32 does. Users have pushed back in anomalyco/opencode#50916, but as of 2026-09-28 no maintainer has said whether LSP will return.

aidevops already verifies through `linters-local.sh`, ShellCheck, and typecheck, and headless profiles set `lsp: false` (`.agents/scripts/headless-runtime-launch.sh:277`). The one missing piece is an explicit rule, so no agent or user expects LSP diagnostics on V2.

## Tier

### Tier checklist (verify before assigning)

- [x] **Exact execution contract supplied?** Every edit has a complete `oldString`/`newString`.
- [x] **Targets and reference pattern verified?** All three files and anchors were checked at HEAD.
- [x] **No semantic or design decision remains?** The direction was decided in the originating session.
- [x] **Bounded, reversible, low-consequence impact?** Documentation only.
- [x] **No stateful coordination to invent?** Three independent insertions.
- [x] **Focused verification and rollback are explicit?** `rg` checks plus markdown lint; revert the commit to roll back.
- [x] **No dispatch-path risk override?** None of the files are in `.agents/configs/self-hosting-files.conf` as dispatch-path code.

**Selected tier:** `tier:simple`

**Tier rationale:** Three verbatim documentation insertions with `rg` verification and a trivial revert.

## PR Conventions

Leaf issue: the PR uses a closing keyword for this issue.

## How (Approach)

### Files to Modify

- `EDIT: .agents/reference/ci-gate-policy.md:20-22` — add the diagnostics-source rule to evidence-guided step 1.
- `EDIT: .agents/build-plus.md:131` — add one clause to the Verify step.
- `EDIT: .agents/tools/opencode/opencode.md:108-110` — add a short `### Language servers (LSP)` subsection before `### Maintaining agent parity`.

### Complete Write Surface

- **Callers/readers:** Build+ loads `.agents/build-plus.md` as its agent prompt. Other files point to `ci-gate-policy.md` (for example `.agents/AGENTS.md` "Prioritise time-to-functional"). `opencode.md` is loaded on demand.
- **Writers/mutation paths:** N/A because this is documentation-only static markdown with no generator.
- **Existing verification/tests:** `rg` checks in the acceptance criteria; `.agents/scripts/linters-local.sh --changed` covers markdown lint.
- **Schemas/config:** N/A — this is a guidance change. The `lsp` config keys stay as they are, including headless `lsp: false`.
- **Generated/deployed mirrors:** `setup.sh` copies `.agents/` to `~/.aidevops/agents/`. No generated file embeds these lines.
- **Migrations/backfills:** N/A because this is documentation-only and stores no state.
- **Cleanup/rollback paths:** Revert the commit that touches `.agents/reference/ci-gate-policy.md`, `.agents/build-plus.md`, and `.agents/tools/opencode/opencode.md`.

### Implementation Steps

1. Edit `.agents/reference/ci-gate-policy.md`.

   oldString:

   ```text
   1. Start with the production-facing behaviour through the existing app, API,
      CLI, integration, or deployment path. Prefer standard logs, telemetry,
      framework diagnostics, and existing targeted checks over synthetic machinery.
   ```

   newString:

   ```text
   1. Start with the production-facing behaviour through the existing app, API,
      CLI, integration, or deployment path. Prefer standard logs, telemetry,
      framework diagnostics, and existing targeted checks over synthetic machinery.
      Get code diagnostics from the project's lint, typecheck, or compiler
      commands; do not depend on editor or runtime LSP diagnostics (OpenCode 2
      does not run language servers).
   ```

2. Edit `.agents/build-plus.md` line 131.

   oldString:

   ```text
   then run the narrowest existing applicable checks. Run required tests
   ```

   newString:

   ```text
   then run the narrowest existing applicable checks; take code diagnostics from the project's lint, typecheck, or compiler commands, not LSP. Run required tests
   ```

3. Edit `.agents/tools/opencode/opencode.md`.

   oldString:

   ```text
   private config/data/auth isolation.

   ### Maintaining agent parity
   ```

   newString:

   ```text
   private config/data/auth isolation.

   ### Language servers (LSP)

   OpenCode 2 accepts and preserves `lsp` configuration, but does not run
   language servers, expose LSP tools, or produce LSP diagnostics; its sidebar
   has no LSP panel. Upstream directs users to the project's lint, typecheck, or
   compiler commands instead (V2 migration guide, `migrate-v1.mdx`). Aidevops
   follows the same rule on every runtime (`reference/ci-gate-policy.md`), and
   headless profiles already set `lsp: false`. OpenCode 1 still supports
   language servers, but framework verification never depends on them.

   ### Maintaining agent parity
   ```

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — static documentation, no runtime state.
- **Migration/rollback:** Revert the commit; no state is written.
- **Mixed-version/backward compatibility:** V1 behaviour is unchanged. The rule only asks for commands that V1 users already run.
- **Idempotency/retry:** Re-applying is a no-op once the text exists; check with `rg` before editing.
- **Partial failure/recovery:** Each edit stands alone; a partial application is valid documentation.

### Verification Before Dispatch

```bash
rg -n "not LSP" .agents/build-plus.md
rg -n "do not depend on editor or runtime LSP diagnostics" .agents/reference/ci-gate-policy.md
rg -n "### Language servers \(LSP\)" .agents/tools/opencode/opencode.md
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Each `rg` check proves one insertion; the changed-file linter proves the markdown is valid.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** No changes to `lsp` config generation, headless profiles, plugin code, or the always-loaded `.agents/AGENTS.md`.

**AI brief owner:** marcusquinn interactive session.

**Recovery:** Preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/reference/ci-gate-policy.md`
- `.agents/build-plus.md`
- `.agents/tools/opencode/opencode.md`

## Acceptance Criteria

- [ ] The CI gate policy states that code diagnostics come from project lint, typecheck, or compiler commands, not LSP.

  ```yaml
  verify:
    method: codebase
    pattern: "do not depend on editor or runtime LSP diagnostics"
    path: ".agents/reference/ci-gate-policy.md"
  ```

- [ ] The OpenCode reference documents V2 LSP status and the upstream alternative.

  ```yaml
  verify:
    method: codebase
    pattern: "### Language servers \\(LSP\\)"
    path: ".agents/tools/opencode/opencode.md"
  ```

- [ ] The Build+ Verify step names lint/typecheck/compiler commands as the diagnostics source.

  ```yaml
  verify:
    method: codebase
    pattern: "compiler commands, not LSP"
    path: ".agents/build-plus.md"
  ```

- [ ] Regression guarantee: `.agents/AGENTS.md` is not changed, so the size ratchet is unaffected.

  ```yaml
  verify:
    method: bash
    run: "git diff --quiet origin/main -- .agents/AGENTS.md"
  ```

- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Decision (maintainer, 2026-09-28): follow upstream's direction rather than reinstate LSP on V2.
- Non-goal: the todo/TodoWrite change. That decision is recorded on #32645 (move task checklists into the conversation).
- Non-goal: V2 promotion canary coverage; it is tracked separately.
- The V1 "all LSPs are disabled" startup log line is reportedly normal lazy activation. It was not verified against source, so it is left out of the docs.

## Relevant Files

- `.agents/reference/ci-gate-policy.md:20` — evidence-guided verification step 1.
- `.agents/build-plus.md:131` — Build+ Verify step.
- `.agents/tools/opencode/opencode.md:108` — end of the runtime-profile section.
- `.agents/scripts/headless-runtime-launch.sh:277` — existing `lsp: false` headless profile (reference only).

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | three anchors |
| Implementation | 10m | three insertions |
| Verification | 5m | `rg` checks and changed-file lint |
| **Total** | **20m** | |
