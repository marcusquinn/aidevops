# t1374: Wire design skill into agent index and update cross-references

## Origin

- **Created:** 2026-03-01
- **Session:** claude-code:interactive
- **Created by:** marcus (human, ai-interactive)
- **Parent task:** none (sibling of t1371, t1372, t1373)
- **Conversation context:** Final integration task for the UI/UX inspiration skill. After t1371-t1373 create the three new files, this task wires them into the framework: subagent index, AGENTS.md domain table, and cross-references from existing agents.

## What

Wire the new design skill files into the aidevops framework:

1. **Update `subagent-index.toon`** — add the new design files to the `tools/design/` entry
2. **Update `.agents/AGENTS.md`** — add design skill to the domain index table
3. **Update `content/guidelines.md`** — add note that when a project has `context/brand-identity.toon`, the brand voice comes from there (guidelines.md provides structural rules only)
4. **Update `content/platform-personas.md`** — add note to read brand-identity.toon for base voice before applying platform shifts
5. **Update `content/production/image.md`** — add note to check brand-identity.toon for imagery and iconography parameters
6. **Update `mobile-app-dev/ui-design.md`** — add reference to ui-ux-catalogue.toon and brand-identity.md
7. **Update `build-plus.md`** — add design skill to the domain expertise check table (step 2b)

## Why

- New files are invisible to agents unless indexed in subagent-index.toon and referenced from AGENTS.md
- Existing content agents won't read brand-identity.toon unless told to
- The design skill is only valuable if it's discoverable and integrated into existing workflows

## How (Approach)

1. Each update is a small edit (1-5 lines) to an existing file
2. Use Edit tool for surgical changes — no rewrites
3. Verify each cross-reference resolves to an actual file path
4. Run markdown-formatter on all modified files

Key files:
- `.agents/subagent-index.toon:26+` — add design files to tools/design/ entry
- `.agents/AGENTS.md` — domain index table
- `.agents/build-plus.md` — domain expertise check table
- `.agents/content/guidelines.md` — add brand identity note
- `.agents/content/platform-personas.md` — add brand identity note
- `.agents/content/production/image.md` — add brand identity note
- `.agents/mobile-app-dev/ui-design.md` — add catalogue reference

## Acceptance Criteria

- [ ] subagent-index.toon tools/design/ entry includes: design-inspiration, ui-ux-inspiration, ui-ux-catalogue, brand-identity
  ```yaml
  verify:
    method: codebase
    pattern: "tools/design/.*ui-ux-inspiration.*brand-identity"
    path: ".agents/subagent-index.toon"
  ```
- [ ] AGENTS.md domain index has a Design entry pointing to the new files
  ```yaml
  verify:
    method: codebase
    pattern: "Design.*tools/design/"
    path: ".agents/AGENTS.md"
  ```
- [ ] content/guidelines.md references brand-identity.toon
  ```yaml
  verify:
    method: codebase
    pattern: "brand-identity"
    path: ".agents/content/guidelines.md"
  ```
- [ ] content/platform-personas.md references brand-identity.toon
  ```yaml
  verify:
    method: codebase
    pattern: "brand-identity"
    path: ".agents/content/platform-personas.md"
  ```
- [ ] content/production/image.md references brand-identity.toon
  ```yaml
  verify:
    method: codebase
    pattern: "brand-identity"
    path: ".agents/content/production/image.md"
  ```
- [ ] All referenced file paths exist
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/tools/design/ui-ux-inspiration.md && test -f .agents/tools/design/ui-ux-catalogue.toon && test -f .agents/tools/design/brand-identity.md"
  ```
- [ ] Lint clean (markdown-formatter on all modified .md files)

## Context & Decisions

- **Minimal edits**: Each existing file gets 1-5 lines added. No rewrites, no restructuring.
- **subagent-index.toon is the discovery mechanism**: Agents find subagents by reading this index. Without the entry, the new files are invisible.
- **guidelines.md stays as-is for structure**: It doesn't get rewritten — just a note added explaining the brand-identity.toon relationship.

## Relevant Files

- All files listed in "How" section above

## Dependencies

- **Blocked by:** t1371, t1372, t1373 (all three files must exist before wiring)
- **Blocks:** nothing (this is the final integration step)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Read current state of each file to edit |
| Implementation | 45m | Small edits to 7 files |
| Testing | 15m | Verify cross-references, lint |
| **Total** | **1.25h** | |
