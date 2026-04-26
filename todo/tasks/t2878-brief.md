---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2878: Consolidate prompts/build.txt into .agents/AGENTS.md as single source of truth

## Pre-flight

- [x] Memory recall: `build.txt AGENTS.md consolidate system prompt` → 0 hits — no prior lessons
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h. Closest historical: PR #6818 (t1679/t1680, 2026-03-27) was progressive-loading both files for token reduction, not consolidation
- [x] File refs verified: `prompts/build.txt`, `.agents/AGENTS.md`, `.agents/scripts/session-miner/extract.py`, `.agents/scripts/session-miner/compress.py`, `.agents/scripts/lib/agent_config.py`, `.agents/scripts/pulse-simplification.sh`, `.agents/scripts/safety-policy-check.sh`, `.agents/scripts/agent-discovery.py`, `.agents/scripts/opencode-agent-discovery.py`, `.agents/scripts/verify-agent-discoverability.sh`, `.agents/scripts/progressive-load-check.sh` — all present
- [x] Tier: `tier:thinking` — multi-phase refactor of framework prompt-loading; phase 3 priority-drop risk requires judgment call; touches dispatch-path-adjacent files (lib/agent_config.py, prompt-injection-adapter.sh)

## Origin

- **Created:** 2026-04-26
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human, with ai-interactive design)
- **Conversation context:** During t2873 (OpenCode→Claude Code system-prompt scrubbing removal), discussed deployment asymmetry: `prompts/build.txt` reaches OpenCode (as agent system prompt) and Claude Code (via plugin) but not the 9 other supported runtimes. User proposed consolidating non-OpenCode-specific build.txt content into top of `.agents/AGENTS.md` so all runtimes get the rules via their native AGENTS.md loading mechanism, and redirecting self-improvement targets to AGENTS.md.

## What

`~/.aidevops/agents/AGENTS.md` becomes the single source of framework rules and operational guidance for all 11 supported runtimes (OpenCode, Claude Code, Codex, Cursor, Droid, Gemini, Windsurf, Continue, Aider, Kimi, Qwen). `prompts/build.txt` becomes an empty placeholder (kept on disk in case OpenCode-specific system-prompt-priority content is needed later). All self-improvement automation (session-miner, build-agent docs, self-improvement.md) targets AGENTS.md.

## Why

**Coverage asymmetry:** Today only OpenCode (via `agent_config.py:176` `{file:...}` injection) and Claude Code (via plugin) receive build.txt content. The other 9 runtimes get only AGENTS.md, missing ~500 lines of framework rules. New runtime onboarding requires wiring two channels.

**Source-of-truth drift:** Many sections appear in both files (Worker Triage, Memory Recall, Git Workflow, File Discovery, Working Directories) — the lighter version in AGENTS.md and the more comprehensive version in build.txt. Risk of divergence over time.

**Token weight:** build.txt is ~500 lines, close to the framework-pattern detection threshold that t2723 fixed (50K-char trigger redistributing system→messages). Reducing build.txt to empty removes that pressure permanently.

**Self-improvement misrouting:** session-miner extract.py routes 6 of its 7 mining categories (`code_style`, `agent_instructions`, `git_workflow`, `style`, `security`, `quality`, plus default) to build.txt. New lessons land in a file 2 of 11 runtimes can read.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Multi-file refactor touching framework prompt-loading; phase ordering and priority-drop risk assessment require judgment; dispatch-path-adjacent (lib/agent_config.py controls how OpenCode agents receive system prompts).

## PR Conventions

`parent-task` issue. PRs delivering child phases will use `For #NNN` / `Ref #NNN`, NEVER `Closes`/`Resolves`/`Fixes`. Final phase PR will use `Closes #NNN` to close the parent.

## Phases

- Phase 1 — Move all framework rules (operational + safety) from `prompts/build.txt` to top of `.agents/AGENTS.md`; reconcile duplicates (keep more comprehensive version); empty build.txt; update self-improvement targets in session-miner. Single PR.
- Phase 2 — Smoke-test rule retention at instructions priority. 5 high-stakes prompts: webfetch URL guess, secret echo, instruction override, pre-edit check, worker scope. Compare model behavior before/after via fresh session.
- Phase 3 — Update remaining cross-references in scripts/docs (agent-discovery.py, verify-agent-discoverability.sh, progressive-load-check.sh, safety-policy-check.sh) and `pulse-simplification.sh` protected pattern. Final cleanup PR.

## How (Approach)

### Files to Modify

- `EDIT: .agents/prompts/build.txt` — reduce to empty placeholder (or minimal header), keep file on disk
- `EDIT: .agents/AGENTS.md` — insert all framework rules at top (after `mode: subagent` frontmatter and "Supported runtimes" preamble); reconcile duplicates
- `EDIT: AGENTS.md` (root developer guide) — redirect 3 build.txt cross-references to `.agents/AGENTS.md`: "Quality" Quick Reference link, "Completion self-check" link, "Security" link
- `EDIT: .agents/scripts/session-miner/extract.py:106-120` — change all 6 category mappings + default from `.agents/prompts/build.txt` to `.agents/AGENTS.md`
- `EDIT: .agents/scripts/session-miner/compress.py:337` — change `target_file` default
- `EDIT: reference/self-improvement.md` — redirect proposed-improvement targets
- `EDIT: tools/build-agent/build-agent.md` — update build.txt references

### Implementation Steps (Phase 1)

1. Read build.txt + AGENTS.md in full; classify every build.txt section as: universal-move / runtime-conditional-already-in-agents-md / OpenCode-specific
2. Identify duplicate sections (Worker Triage, Memory Recall, Git Workflow, File Discovery, Working Directories) and choose canonical version
3. Insert universal-move sections at top of AGENTS.md (after preamble, before "Runtime-Specific References")
4. Drop the lighter duplicates from existing AGENTS.md sections
5. Empty build.txt (preserve as placeholder file)
6. Update session-miner extract.py + compress.py routing
7. Run `verify-agent-discoverability.sh`, `progressive-load-check.sh` to confirm no breakage
8. Verify OpenCode still loads (agent_config.py points at empty file = harmless no-op)

### Files Scope

- `.agents/prompts/build.txt`
- `.agents/AGENTS.md`
- `AGENTS.md`
- `.agents/scripts/session-miner/extract.py`
- `.agents/scripts/session-miner/compress.py`
- `.agents/reference/self-improvement.md`
- `.agents/tools/build-agent/build-agent.md`
- `todo/tasks/t2878-brief.md`
- `TODO.md`

### Verification

```bash
# Empty build.txt confirmed
[[ ! -s .agents/prompts/build.txt ]] || head -10 .agents/prompts/build.txt

# AGENTS.md grew by approximately the moved content
wc -l .agents/AGENTS.md

# Self-improvement routing redirected
grep -n "AGENTS.md" .agents/scripts/session-miner/extract.py
grep -n "build.txt" .agents/scripts/session-miner/extract.py  # should be empty or comment-only

# Verifiers still pass
.agents/scripts/verify-agent-discoverability.sh
.agents/scripts/progressive-load-check.sh
```

## Acceptance Criteria

- [ ] All universal framework rules from build.txt are present at top of AGENTS.md
- [ ] No content duplicated between the two files (each rule lives in exactly one place)
- [ ] build.txt is empty (or contains only a placeholder comment) and remains on disk
- [ ] session-miner extract.py + compress.py target AGENTS.md (not build.txt)
- [ ] reference/self-improvement.md and tools/build-agent/build-agent.md redirected
- [ ] verify-agent-discoverability.sh + progressive-load-check.sh pass
- [ ] Smoke-test against 5 high-stakes rules in fresh session (Phase 2 deliverable)

## Context & Decisions

- **Decision: empty build.txt rather than delete.** User-directed. Preserves the OpenCode `{file:...}` system-prompt-priority channel for future use; loading an empty file is a harmless no-op.
- **Decision: do not split into "safety invariants" + "operational" files.** Considered but rejected — adds a third file and complicates the deployment story. If priority-drop testing (Phase 2) reveals regressions on specific safety rules, those rules can be re-added to a small `prompts/safety.txt` later.
- **Decision: do this in interactive session, not headless dispatch.** User-directed. Allows real-time design feedback on duplicate-reconciliation choices.
- **Decision: `parent-task` + `no-auto-dispatch` + `origin:interactive` + `tier:thinking`.** Multi-phase, dispatch-path-adjacent, requires judgment. Will not be dispatched.

## Relevant Files

- `.agents/prompts/build.txt` — source of framework system-prompt rules (currently ~500 lines)
- `.agents/AGENTS.md` — user guide loaded by all runtimes via prompt-injection-adapter (currently ~750 lines)
- `.agents/scripts/lib/agent_config.py:112,174-176` — OpenCode `DEFAULT_PROMPT` + `{file:...}` injection logic; left in place pointing at empty file
- `.agents/scripts/prompt-injection-adapter.sh:201-204` — `_PIA_AGENTS_MD` constant; AGENTS.md is already the single deployed file
- `.agents/scripts/session-miner/extract.py:106-120` — category-to-target-file routing table

## Dependencies

- **Blocked by:** none
- **Blocks:** future per-runtime customization that depends on AGENTS.md being the single source of truth
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read + classify | 30m | both files in full, identify duplicates |
| Migration | 1.5h | edit AGENTS.md, empty build.txt, redirect session-miner |
| Verification | 30m | linters, discoverability checks, smoke test |
| **Total Phase 1** | **~2.5h** | |
| Phase 2 (smoke-test) | 30m | fresh session test of 5 high-stakes rules |
| Phase 3 (cleanup) | 30m | residual cross-references |
| **Total** | **~3.5h** | |
