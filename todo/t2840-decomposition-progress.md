# Session checkpoint — t2840 decomposition

**Last updated:** 2026-04-25 (after parent brief, before P0 phase)

## Parent
- Task ID: `t2840` / `GH#20892`
- URL: https://github.com/marcusquinn/aidevops/issues/20892
- Worktree: `/Users/marcusquinn/Git/aidevops-feature-t2840-knowledge-planes-mvp`
- Branch: `feature/t2840-knowledge-planes-mvp` (base origin/main)
- Status: `status:in-review`, locked to marcusquinn (interactive)
- Brief committed: ✅ at `todo/tasks/t2840-brief.md` (commit 0b36a4795)

## 16 children to file (next available: t2842 — t2841 taken by another session)

Predicted ID assignments (race-tolerant — actual IDs from claim output):

| Phase | Predicted ID | Title | Tier | Blocked-by |
|---|---|---|---|---|
| P0a | t2842 | knowledge plane directory contract + provisioning | standard | (parent merged) |
| P0b | t2843 | knowledge CLI surface (add/list/search) + platform abstraction | standard | (parent merged) |
| P0c | t2844 | knowledge review gate routine + NMR integration | standard | t2842, t2843 |
| P0.5a | t2845 | sensitivity classification schema + detector | standard | t2842 |
| P0.5b | t2846 | LLM routing helper + audit log | standard | t2845, t2847 |
| P0.5c | t2847 | Ollama integration + local LLM substrate | standard | t2842 |
| P1a | t2848 | kind-aware enrichment + structured field extraction | standard | t2842, t2843 |
| P1c | t2849 | PageIndex tree generation across corpus | standard | t2842 |
| P4a | t2850 | case dossier contract + `aidevops case open` | standard | t2842, t2843, t2845 |
| P4b | t2851 | case CLI (attach/status/close/archive/list) | standard | t2850 |
| P4c | t2852 | case milestone + deadline alarming routine | standard | t2850 |
| P5a | t2853 | `.eml` ingestion handler (kind=email) | standard | t2842, t2843, t2848 |
| P5b | t2854 | IMAP polling routine + `mailboxes.json` registry | standard | t2853 |
| P5c | t2855 | email thread reconstruction + filter→case-attach | standard | t2853, t2854, t2850 |
| P6a | t2856 | `aidevops case draft` agent (RAG, human-gated, provenance) | thinking | t2850, t2851, t2849 |
| P6b | t2857 | `aidevops case chase` (template-only, opt-in auto-send) | standard | t2850, t2851 |

## Standard child labels

`tier:standard` (or `tier:thinking` for P6a) + `enhancement` + `framework` + `auto-dispatch` (so workers pick up after parent planning PR merges) + `origin:interactive` + `phase:P0|P0.5|P1|P4|P5|P6`.

`#blocked-by:tNNN` in TODO entry tags translates to `blocked-by:tNNN` text in body (issue-sync extracts it).

## Standard child brief skeleton

```markdown
---
mode: subagent
---

# tNNN: <title>

## Pre-flight
- [x] Memory recall: <query> → <result>
- [x] Discovery: <recent commits/PRs touching files>
- [x] File refs verified: <list>
- [x] Tier: <tier> — <rationale>

## Origin
- Created: <date>
- Parent task: t2840 / GH#20892
- Phase: <P0|P0.5|...>

## What
<1-2 paragraphs>

## Why
<reference parent brief Why section + this child's specific contribution>

## How (Approach)
1. <step with file:line refs>
2. ...
3. ...

### Files Scope
- NEW: <path>
- EDIT: <path:line>

## Acceptance Criteria
- [ ] <verifiable>
- [ ] <verifiable>
- [ ] Tests pass: <command>
- [ ] Documentation: <path updated>

## Dependencies
- Blocked by: <list>
- Blocks: <list>

## Reference
- Parent brief: `todo/tasks/t2840-brief.md`
- Sub-section: <which subsection of parent.How>
```

## After all 16 children filed

- [ ] Parent issue body (GH#20892) updated with child task ID list
- [ ] TODO.md verified: parent + 16 children entries with `ref:GH#NNN`
- [ ] Planning PR opened: `For #20892` keyword (NEVER `Resolves`/`Closes`)
- [ ] PR title: `t2840: decompose knowledge planes MVP into 16 children`
- [ ] PR body lists all child IDs/issue numbers + brief paths

## Next action (if compacted)

1. `cd /Users/marcusquinn/Git/aidevops-feature-t2840-knowledge-planes-mvp`
2. Read `.session-progress.md` (this file)
3. Read `todo/tasks/t2840-brief.md` (parent brief)
4. Check which P-phase is next via TODO.md / GH issues
5. Resume from "P0a" if no children filed yet; otherwise continue from first unfiled phase

## Phase progress log

- [x] P0 (P0a, P0b, P0c) — 3 children filed (t2843/GH#20895, t2844/GH#20896, t2845/GH#20897)
- [x] P0.5 (P0.5a, P0.5b, P0.5c) — 3 children filed (t2846/GH#20898, t2847/GH#20899, t2848/GH#20900)
- [x] P1 (P1a, P1c) — 2 children filed (t2849/GH#20901, t2850/GH#20902)
- [x] P4 (P4a, P4b, P4c) — 3 children filed (t2851/GH#20903, t2852/GH#20904, t2853/GH#20905)
- [x] P5 (P5a, P5b, P5c) — 3 children filed (t2854/GH#20906, t2855/GH#20907, t2856/GH#20908)
- [x] P6 (P6a, P6b) — 2 children filed (t2857/GH#20911, t2858/GH#20912)
- [x] Parent body update + planning PR (#20913 opened with `For #20892`)

## Follow-up framework bugs surfaced during this session

| Task | Issue | Severity | Notes |
|---|---|---|---|
| t2859 | GH#20914 / PR#20915 | high | unbound `ORPHAN_WORKTREE_GRACE_SECS` in pulse-cleanup.sh — destroyed 49 worktrees in 1h. Fix landed in PR. |
| t2860 | GH#20917 | medium | `_cleanup_single_worktree` doesn't call `unregister_worktree` after destroying — 815 stale registry entries. |
| t2861 | GH#20918 | medium | gh PATH shim mutates `--body-file` source on disk. Filed using the workaround we documented. |

All three: `no-auto-dispatch` + `origin:interactive` (dispatch-path adjacent) — maintainer review before any worker takes them.
