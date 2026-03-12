# t1451: Add Context7 CLI subagent and hybrid MCP fallback docs

## Origin

- **Created:** 2026-03-12
- **Session:** OpenCode interactive request
- **Created by:** OpenCode gpt-5.3-codex
- **Parent task:** none
- **Conversation context:** The user requested implementation of a Context7 CLI agent after enabling `npx ctx7 setup`, with the goal of using CLI lookups as a context-saving alternative when MCP transport is not ideal.

## What

Create a dedicated Context7 CLI subagent and update Context7 documentation so aidevops supports a clear hybrid strategy: MCP-first for normal workflows, CLI fallback for shell-native and constrained cases.

## Why

- The repo already supports Context7 via MCP, but lacks a focused CLI execution path for `ctx7 library` and `ctx7 docs`.
- A documented fallback reduces friction when MCP transport is unavailable or unreliable.
- CLI JSON output improves deterministic scripting and context-token efficiency for shell pipelines.

## How (Approach)

1. Add `.agents/tools/context/context7-cli.md` with YAML frontmatter and CLI usage guidance.
2. Update `.agents/tools/context/context7.md` to include hybrid backend guidance and CLI command equivalents.
3. Update `README.md` AI/documentation section with `npx ctx7 setup --opencode --cli` setup guidance.
4. Regenerate subagent index and run markdown lint on changed docs.

## Acceptance Criteria

- [ ] `.agents/tools/context/context7-cli.md` exists with actionable CLI workflow and verification prompt.
- [ ] `.agents/tools/context/context7.md` documents MCP-first + CLI-fallback strategy.
- [ ] `README.md` mentions Context7 CLI setup mode for OpenCode.
- [ ] Markdown lint passes for all touched documentation files.

## Context & Decisions

- Keep the existing `@context7` MCP path as default to avoid disrupting current workflows.
- Introduce CLI as additive capability, not replacement, to minimize migration risk.
- Prefer `--json` in CLI examples to support deterministic post-processing.

## Relevant Files

- `.agents/tools/context/context7-cli.md`
- `.agents/tools/context/context7.md`
- `README.md`
- `TODO.md`

## Dependencies

- **Blocked by:** none
- **Blocks:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | confirm `ctx7` command surface |
| Implementation | 30m | add subagent + docs updates |
| Testing | 15m | markdown lint + index regeneration |
| **Total** | **~1h** | |
