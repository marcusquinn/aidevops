---
mode: subagent
---
# t1417: Add pulse hygiene layer — stash cleanup, orphan worktree detection, stale PR triage

## Origin

- **Created:** 2026-03-08
- **Session:** claude-code:t1417-hygiene
- **Created by:** ai-interactive (Marcus requested systemic cleanup)
- **Conversation context:** Investigation of 76 accumulated worktrees, 28 stashes, and 28 open PRs revealed that the pulse handles merged-PR worktree cleanup deterministically but has no mechanism for stash cleanup, orphan worktree detection, or stale PR triage. The deterministic layer (stash-audit-helper.sh) exists but isn't wired into the pulse. The intelligence layer (pulse.md instructions) has no hygiene triage section.

## What

Three additions to the pulse cycle:

1. **Deterministic stash cleanup** — Wire `stash-audit-helper.sh auto-clean` into `pulse-wrapper.sh` so safe-to-drop stashes are cleaned every pulse cycle across all managed repos.

2. **Hygiene data in pre-fetched state** — Add `prefetch_hygiene()` to `pulse-wrapper.sh` that appends to the state file: orphan worktrees (0 commits, no PR, no active worker), stash summary, and uncommitted changes on main.

3. **LLM hygiene triage instructions** — Add a "Repo Hygiene Triage" section to `pulse.md` instructing the pulse LLM to assess orphan worktrees, stale PRs (failing CI 7+ days), and flag ambiguous situations rather than auto-removing.

## Why

Workers crash, apps quit, systems reboot — leaving orphan worktrees, stale stashes, and abandoned PRs. Without systemic cleanup, these accumulate (76 worktrees observed). Merged-PR cleanup is deterministic and already works. Everything else requires intelligence — the LLM must assess whether an orphan branch has value, whether a stale PR should be closed or fixed, whether uncommitted changes on main are intentional.

This is productivity-enhancing infrastructure — every pulse cycle benefits from cleaner state, and workers dispatched into repos with less cruft are more effective.

## How (Approach)

### pulse-wrapper.sh changes:
- Add `cleanup_stashes()` function following the `cleanup_worktrees()` pattern — iterate repos.json, call `stash-audit-helper.sh auto-clean --repo <path>` for each
- Add `prefetch_hygiene()` function that appends a `# Repo Hygiene` section to STATE_FILE with orphan worktree list, stash counts, and uncommitted changes on main
- Wire both into `main()` — stash cleanup alongside worktree cleanup, hygiene prefetch alongside existing prefetch

### pulse.md changes:
- Add "Repo Hygiene Triage" section after the existing PR/issue sections
- Instructions for the LLM to assess orphan worktrees (flag, don't auto-remove)
- Instructions for stale PR closing (7+ days failing CI, no commits, no worker → close with comment)
- Instructions for uncommitted changes on main (flag to user)

## Acceptance Criteria

- [ ] `stash-audit-helper.sh auto-clean` is called for each managed repo during pulse cycle
  ```yaml
  verify:
    method: codebase
    pattern: "stash-audit-helper.sh.*auto-clean"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] Pre-fetched state includes orphan worktree data for LLM triage
  ```yaml
  verify:
    method: codebase
    pattern: "prefetch_hygiene|Repo Hygiene"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] pulse.md has hygiene triage instructions
  ```yaml
  verify:
    method: codebase
    pattern: "Hygiene Triage|orphan.*worktree|stale.*PR"
    path: ".agents/scripts/commands/pulse.md"
  ```
- [ ] ShellCheck clean on modified scripts
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-wrapper.sh"
  ```
- [ ] Orphan worktrees are NOT auto-removed — only flagged for LLM assessment
  ```yaml
  verify:
    method: subagent
    prompt: "Review pulse.md hygiene section. Confirm orphan worktrees are flagged for assessment, not auto-removed. The LLM should use judgment, not deterministic rules."
  ```

## Context & Decisions

- **Merged-PR worktrees = deterministic cleanup** (already works via worktree-helper.sh clean --auto --force-merged)
- **Everything else = intelligence** — orphan worktrees, stale PRs, ambiguous stashes need LLM judgment
- **stash-audit-helper.sh already exists** with safe classification (safe-to-drop = all changes in HEAD)
- **Architecture: shell layer for deterministic, LLM layer for judgment** — consistent with the framework's "intelligence over determinism" principle
- Stale PR threshold: 7 days failing CI with no new commits — long enough to avoid false positives from weekend pauses

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh` — Main pulse orchestration (cleanup_worktrees at line 1318, prefetch_state at line 363, main at line 2797)
- `.agents/scripts/commands/pulse.md` — Pulse LLM instructions (orphan PR detection at line 559)
- `.agents/scripts/stash-audit-helper.sh` — Existing stash audit tool (auto-clean command)
- `.agents/scripts/worktree-helper.sh` — Existing worktree cleanup (cmd_clean at line 685)

## Dependencies

- **Blocked by:** None
- **Blocks:** Cleaner pulse state for all managed repos
- **External:** None

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Already done — full analysis in conversation |
| Implementation | 45m | pulse-wrapper.sh + pulse.md changes |
| Testing | 15m | ShellCheck + manual review |
| **Total** | **~1h15m** | |
