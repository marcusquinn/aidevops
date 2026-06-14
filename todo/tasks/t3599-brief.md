# t3599: Document app-stack guidance

## Origin

- **Created:** 2026-06-14
- **Session:** OpenCode interactive session
- **Created by:** ai-interactive
- **Task ref:** GH#24768
- **PR:** #24767

## What

Add public app-stack guidance for platform selection, no-build static sites,
TypeScript monorepos, Electron desktop, workspace boundaries, database
foundation, metadata-driven architecture, encrypted collaboration, and UX shell
patterns.

## Why

Aidevops needs reusable public guidance for choosing and shaping common app
stacks without relying on private repo or app names. The guidance should route
future sessions to the right static-site, WordPress, monorepo, database,
desktop, mobile, and extension patterns.

## Tier

**Selected tier:** `tier:standard`

Rationale: documentation-only change across multiple focused guidance files,
with routing/index updates and framework validation.

## How

### Files modified

- `NEW: .agents/tools/app-stack.md`
- `NEW: .agents/tools/app-stack/decision-matrix.md`
- `NEW: .agents/tools/app-stack/static-site-starter.md`
- `NEW: .agents/tools/app-stack/monorepo-app-stack.md`
- `NEW: .agents/tools/app-stack/electron-desktop.md`
- `NEW: .agents/tools/app-stack/workspace-model.md`
- `NEW: .agents/tools/app-stack/database-foundation.md`
- `NEW: .agents/tools/app-stack/metadata-architecture.md`
- `NEW: .agents/tools/app-stack/encrypted-collaboration.md`
- `NEW: .agents/tools/app-stack/ux-shell-patterns.md`
- `EDIT: .agents/reference/domain-index.md`
- `EDIT: .agents/reference/agent-routing.md`
- `EDIT: .agents/subagent-index.toon`

### Reference pattern

Follow existing orchestrator and progressive-disclosure docs such as
`.agents/tools/wordpress.md` and `.agents/reference/domain-index.md`: keep the
root orchestrator compact, place detail in focused subagent docs, and add only
minimal routing/index pointers.

### Implementation notes

1. Add `tools/app-stack.md` as the orchestrator and route table.
2. Add focused docs for decision matrix, static sites, monorepos, Electron,
   workspaces, database foundation, metadata architecture, encrypted
   collaboration, and UX shell patterns.
3. Keep wording public-safe: no private repo/app names, private local paths, or
   client-specific details.
4. Update domain routing and subagent index with minimal focused entries.

### Verification

```bash
git diff --check origin/main...HEAD
AIDEVOPS_AGENTS_DIR=.agents .agents/scripts/subagent-index-helper.sh check
.agents/scripts/linters-local.sh
```

## Acceptance criteria

- [x] App-stack orchestrator and focused docs exist.
- [x] Guidance is public-safe and contains no private repo/app names or local
  paths.
- [x] Database foundation standardizes Workspace, accounts, contacts, and
  synonym mapping.
- [x] Domain routing and subagent index include the new app-stack docs.
- [x] Verification evidence is recorded in PR #24767.

## Context

This brief was added after PR creation because the linked-issue gate requires a
task issue. The implementation already exists in PR #24767 and resolves
GH#24768.
