<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t1920: Fix planning filter false positive (p002: prefix and docs/ paths)

## Context
- **Session Origin**: Interactive review of GH#17761
- **Issue**: [GH#17761](https://github.com/marcusquinn/aidevops/issues/17761)
- **File**: `.agents/scripts/pulse-wrapper.sh`
- **Prior Art**: #17707 (incomplete fix), #17574 (introduced `_is_task_committed_to_main`)

## What
Fix two filter gaps in `_is_task_committed_to_main` that cause planning-only commits to be misclassified as implementation, blocking pulse dispatch.

## Why
Plan commits using the `p002:` prefix convention and commits touching `docs/` directories are not caught by the planning filter. This causes false-positive dedup blocks — tasks with only planning commits are permanently marked as "already committed to main" and never dispatched. Currently blocking t099 and 12 downstream tasks.

## How
1. EDIT: `.agents/scripts/pulse-wrapper.sh:6806` — expand subject-line filter regex to include `p[0-9]+:` plan prefixes:
   ```bash
   # Current:
   grep -vE '^[0-9a-f]+ (chore: claim|plan:)'
   # Fixed:
   grep -vE '^[0-9a-f]+ (chore: claim|plan:|p[0-9]+:)'
   ```
2. EDIT: `.agents/scripts/pulse-wrapper.sh:6794` — expand planning-path whitelist to include docs directories:
   ```bash
   # Current:
   TODO.md | todo/* | AGENTS.md | .agents/AGENTS.md) ;;
   # Fixed:
   TODO.md | todo/* | AGENTS.md | .agents/AGENTS.md | */docs/* | docs/*) ;;
   ```

**Reference pattern**: Follow existing filter structure at the same lines. Both changes are additive — extend existing regex/glob, don't restructure.

## Acceptance Criteria
- [ ] Subject filter at ~L6806 matches `p[0-9]+:` prefixed commits (e.g., `p002: add Phase 10 plan`)
- [ ] Path whitelist at ~L6794 includes `*/docs/*` and `docs/*` patterns
- [ ] Verification: `echo "ed66537 p002: add Phase 10 plan" | grep -vE '^[0-9a-f]+ (chore: claim|plan:|p[0-9]+:)'` returns empty (commit filtered out)
- [ ] Verification: `case "shared/deep-research/docs/design-cross-topic-knowledge-compounding.md" in TODO.md|todo/*|AGENTS.md|.agents/AGENTS.md|*/docs/*|docs/*) echo "planning";; *) echo "impl";; esac` returns "planning"
- [ ] ShellCheck passes on modified lines
