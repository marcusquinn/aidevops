---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3604: render reusable workflow comment references for configured targets

## Pre-flight

- [x] Memory recall: `issue 25166 reusable workflow comments _render_template_for_target TODO task brief` → 0 relevant hits.
- [x] Duplicate/collision check: `TODO.md`/`todo/tasks/*.md` contained no `ref:GH#25166`; existing reusable target task is completed t3594/GH#24520 and did not cover comment rendering.
- [x] File refs verified at HEAD `85103e2f0`: `.agents/scripts/check-workflows-helper.sh:215-225`, `.agents/scripts/tests/test-check-workflows-helper.sh:339-368`, `.agents/templates/workflows/issue-sync-caller.yml:3-5,57`.
- [x] Tier: `tier:simple` — one helper function plus focused regression test; no new config or trust-boundary design.

## Origin

- **Created:** 2026-06-20
- **Session:** OpenCode interactive follow-up from `/review-issue-pr` on GH#25166.
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** — standalone leaf for GH#25166.
- **Blocked by:** — none known.
- **Conversation context:** Issue review approved GH#25166 as a real `check-workflows` false positive and found dispatchability missing: no task ID, TODO entry, or worker-ready brief.

## What

Fix `aidevops check-workflows` so canonical caller templates are rendered consistently when `workflow_reusable_repo`/`workflow_reusable_ref` points at an organization-owned reusable workflow repository.

Today `_render_template_for_target()` updates only the `uses:` line:

```bash
sed -E "s|(uses:[[:space:]]*)${_DEFAULT_WORKFLOW_REUSABLE_REPO}(/\.github/workflows/${_reusable_escaped})@[^[:space:]]+|\1${_repo_repl}\2@${_ref_repl}|" "$_template"
```

Template comments such as `# Upstream logic lives in: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml` remain unrendered. Org-owned callers with equivalent comments can then fail byte comparison and classify as `DRIFTED/CALLER` even though the functional caller is current.

## Why

GH#24538/t3594 intentionally supports configured reusable workflow targets for organizations that mirror or review workflow logic in `ORG/.github`. Comment-only drift is noise: it blocks operators from seeing real workflow drift and can trigger unnecessary worker/maintainer cycles. The fix should preserve the existing strict trust model while rendering documentation references for the same exact reusable workflow path.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** Yes — expected helper + test only.
- [x] **Every target file under 500 lines?** Yes for the test; helper is >500 but edit is a small existing function with exact anchor.
- [x] **Exact edit anchor known?** Yes — `.agents/scripts/check-workflows-helper.sh:215-225`.
- [x] **No broad design decisions?** Yes — targeted path rendering only.
- [x] **Estimate 1h or less?** Yes — ~45m.
- [x] **4 or fewer acceptance criteria?** Yes.

**Selected tier:** `tier:simple`

**Tier rationale:** Minimal regression fix around existing renderer/test pattern. Do not expand into comment-stripping, sync rendering redesign, or reusable-content update checks.

## PR Conventions

Leaf issue — PR body should use `Resolves #25166`.

## Seeded Draft PR

- **Decision:** Skipped.
- **Rationale:** The issue and review already identify the exact helper/test surface. A seeded partial change risks anchoring a workflow safety fix without verification.
- **Status:** `not-created`.
- **Stale-assumption warning:** Re-check target lines and open PRs before editing; workflow helpers are active automation surfaces.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/check-workflows-helper.sh` — update `_render_template_for_target()` so it renders both:
  - `uses: marcusquinn/aidevops/.github/workflows/<reusable-file>@<ref>` → configured repo/ref.
  - Exact documentation/reference occurrences of `marcusquinn/aidevops/.github/workflows/<reusable-file>` → configured repo, without changing unrelated repo text.
- `EDIT: .agents/scripts/tests/test-check-workflows-helper.sh` — add or adjust a regression near the existing org-owned configured target tests (`Test 13`/`Test 14`).

### Current Evidence / Verified Anchors

- `.agents/scripts/check-workflows-helper.sh:215-225` renders only `uses:` lines.
- `.agents/scripts/tests/test-check-workflows-helper.sh:339-352` already covers org-owned pinned callers but uses a global replacement, so it does not expose comment-only drift.
- `.agents/scripts/tests/test-check-workflows-helper.sh:355-368` already asserts unconfigured third-party callers remain `NEEDS-MIGRATION`.
- `.agents/templates/workflows/issue-sync-caller.yml:4` contains a comment reference to `marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml`; line 57 contains the functional `uses:` target.

### Implementation Steps

1. Update `_render_template_for_target()` using existing escaping helpers:
   - Keep `_reusable_escaped`, `_repo_repl`, and `_ref_repl`.
   - First render the `uses:` line as today.
   - Then render exact reusable workflow path references matching `${_DEFAULT_WORKFLOW_REUSABLE_REPO}/.github/workflows/${_reusable_file}` to `${_repo}/.github/workflows/${_reusable_file}`.
   - Keep the replacement scoped to the reusable workflow path; do not globally replace `marcusquinn/aidevops` or ignore YAML comments.

2. Add regression coverage:
   - Build a fixture from the canonical template.
   - Replace the `uses:` line with `ORG/.github/.github/workflows/issue-sync-reusable.yml@1234567890abcdef1234567890abcdef12345678`.
   - Replace the upstream comment reference with an org-owned comment/reference containing `ORG/.github/.github/workflows/issue-sync-reusable.yml`.
   - Configure `workflow_reusable_repo: "ORG/.github"` and matching `workflow_reusable_ref`.
   - Assert classification is `CURRENT/CALLER`.
   - Preserve the unconfigured `OTHER/.github` negative assertion.

3. Guard scope:
   - Do not change `_downstream_pattern` trust matching except as required by the regression.
   - Do not strip or ignore comments wholesale.
   - Do not update sync-workflows unless a failing regression proves the same renderer bug exists there; if found, add a follow-up task or expand only with evidence.

### Verification

Run from repo root:

```bash
.agents/scripts/tests/test-check-workflows-helper.sh
shellcheck .agents/scripts/check-workflows-helper.sh .agents/scripts/tests/test-check-workflows-helper.sh
```

If touched shell code fails broader local lint, run:

```bash
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

- [ ] Org-owned configured caller with comment/reference differences for the same reusable workflow path classifies as `CURRENT/CALLER`.
- [ ] Unconfigured third-party reusable workflow repos still do not classify as current.
- [ ] Rendering is scoped to the exact reusable workflow path and does not globally replace repo strings or ignore YAML comments.
- [ ] Focused test and ShellCheck pass.

## References

- GH#25166 — false positive `DRIFTED/CALLER` for org-owned reusable workflow comments.
- GH#24520 / PR #24538 / t3594 — configured reusable workflow repository/ref support.
- `.agents/reference/reusable-workflows.md` — reusable workflow architecture and configured target context.
