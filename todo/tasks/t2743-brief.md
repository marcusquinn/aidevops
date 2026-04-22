<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2743 — Fix shared-gh-wrappers REST fallback to work in zsh (drops labels+assignees silently)

**Canonical brief lives in the GitHub issue body (worker-ready per t2417 heuristic):**

- Issue: [marcusquinn/aidevops#20480](https://github.com/marcusquinn/aidevops/issues/20480)

This stub exists because the issue body meets the t2417 worker-ready threshold (7+ heading signals: Session Origin, What, Why, How, Acceptance, Context, Tier checklist, Routing). Duplicating content here would create the collision surface described in GH#20015. Read the issue body, not this file.

## Quick reference (for grep / backfill)

- **Task ID**: t2743
- **Issue**: GH#20480
- **Tier**: `tier:standard`
- **Origin**: `origin:interactive` (filed by maintainer during t2742 session when REST fallback dropped labels silently)
- **Files**:
  - `.agents/scripts/shared-gh-wrappers-rest-fallback.sh` (14 sites using `read -ra`)
  - `.agents/scripts/shared-gh-wrappers.sh` (load-order fix at `:56-58`, `print_info` stub)
  - `.agents/scripts/tests/test-gh-wrapper-shell-compat.sh` (new)
- **Precedent**: Follow-up to #20243 (t2574) which introduced the REST fallback; and t2689 which refactored it. Neither test suite exercised zsh, so the bug was invisible until an interactive zsh session hit GraphQL exhaustion.
- **Cross-platform**: Must work in bash 3.2 (macOS default), zsh 5+ (macOS interactive default), bash 4+/5+ (Linux workers) — POSIX parameter expansion only, no `read -ra` / `read -A` / `mapfile`
- **Blast radius**: interactive issue/PR filing during GraphQL exhaustion — silently strips labels, forcing REST catch-up calls
