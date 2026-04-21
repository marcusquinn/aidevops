# t2692: scrub private repo references from aidevops codebase

## Session Origin

- **Branch:** feature/t2692-privacy-scrub-private-repo-refs
- **Runtime:** OpenCode v1.14.19
- **Created by:** ai-interactive (user flagged cross-repo privacy leak after t2685 shipped)
- **Conversation context:** During the t2685 signature-footer hardening session, the agent composed issue/PR/brief/commit content that referenced a managed private repo by name. The user flagged this as a privacy violation: the private repo name must not appear in the aidevops codebase. Separately, the privacy-guard was structurally unable to catch it because the repo's entry in `~/.config/aidevops/repos.json` had `local_only: null` and `mirror_upstream: null` — the guard treats only repos with one of those flags set as private.

## What

Two coordinated fixes:

1. **Code-tree scrub**: replace every occurrence of the private repo slug and URL with the generic placeholder `webapp` across 21 files (TODO.md, 7 brief files, 1 research doc, 6 scripts + top-level `aidevops.sh`, 5 test files).
2. **Privacy-guard config fix** (already applied out-of-band): `~/.config/aidevops/repos.json` → `mirror_upstream: true` on the private repo entry, and `~/.aidevops/configs/privacy-guard-extra-slugs.txt` created with the slug so the guard catches any future regression regardless of repos.json state.

## Why

Cross-repo privacy rule (`prompts/build.txt` + `.agents/AGENTS.md`) is explicit: private repo names must never appear in the aidevops codebase. The leak is most severe in:

- Public issue bodies and PR descriptions (already scrubbed via REST PATCH)
- TODO.md entries (scrubbed in this PR)
- Brief files (scrubbed in this PR)
- Script comments that narrate incident context (scrubbed in this PR)

The 49 commit-message bodies across git history cannot be scrubbed without force-pushing main — explicitly forbidden by the framework safety rules. This PR handles everything else.

## How

Ordered perl regex replacement (URL → pair form → bare name) applied per-file. See the commit diff for the exact substitutions.

### Files Scope

- EDIT: TODO.md
- EDIT: todo/tasks/t2685-brief.md
- EDIT: todo/tasks/t2434-brief.md
- EDIT: todo/tasks/t2112-brief.md
- EDIT: todo/tasks/t2113-brief.md
- EDIT: todo/tasks/t2114-brief.md
- EDIT: todo/tasks/t2031-brief.md
- EDIT: todo/tasks/t1968-brief.md
- EDIT: todo/research/optimize-brief-tiers.md
- EDIT: aidevops.sh
- EDIT: .agents/scripts/post-merge-review-scanner.sh
- EDIT: .agents/scripts/pulse-dispatch-worker-launch.sh
- EDIT: .agents/scripts/pulse-merge.sh
- EDIT: .agents/scripts/pulse-dep-graph.sh
- EDIT: .agents/scripts/pulse-issue-reconcile.sh
- EDIT: .agents/scripts/tests/test-pulse-dep-graph-non-dep-block.sh
- EDIT: .agents/scripts/tests/test-parent-decomposition-nudge-dedup.sh
- EDIT: .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh
- EDIT: .agents/scripts/tests/test-pulse-dispatch-core-bot-cleanup.sh
- EDIT: .agents/scripts/tests/test-upgrade-planning-sections.sh
- EDIT: .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh
- NEW: todo/tasks/t2692-brief.md

## Acceptance

- [x] `rg "<private-slug>" .agents/ todo/ TODO.md` returns zero matches
- [x] All scrubbed shell scripts pass `bash -n` (syntax OK)
- [x] Privacy-guard config sees the slug (verified: `repos.json` has `mirror_upstream: true`, extras file exists with slug)
- [x] No broken task IDs or cross-references introduced

## Follow-up / Out of Scope

- Commit-message bodies on main (49 commits across history). Fixing requires force-push on main, which is explicitly forbidden by framework safety rules. Accepting the historical leak; the scrub prevents future accretion.
- Memory DB (local, already scrubbed out-of-band: 121 rows UPDATEd via SQLite REPLACE).
- Issue #20306 body and PR #20307 body (already scrubbed out-of-band via REST PATCH).
