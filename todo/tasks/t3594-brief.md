---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3594: support configured reusable workflow repository targets

## Pre-flight

- [x] Memory recall: `workflow target resolution check-workflows sync-workflows reusable workflow` → 0 hits — no relevant accumulated lessons found.
- [x] Discovery pass: 1 commit / 0 merged PRs / 0 open PRs touch or mention target files since issue creation + 2h. The commit (`59de4e903`) touched TODO context only and did not implement GH#24520; no collision found for `24520 workflow reusable repo check-workflows sync-workflows`.
- [x] File refs verified: 5 refs checked at HEAD: `.agents/scripts/check-workflows-helper.sh:157,214`, `.agents/scripts/sync-workflows-helper.sh:203,257`, `.agents/templates/workflows/issue-sync-caller.yml:57`; runner test pattern verified at `.agents/scripts/tests/test-sync-workflows-helper.sh:267-310`.
- [x] Tier: `tier:standard` — multiple shell helpers/templates/tests, shared resolver design, validation, and regression authoring; known runner/config patterns exist, so not `tier:thinking`.
- [x] Seeded draft PR decision recorded: skipped — issue body plus review comment contain enough context; no implementation seed is safer than an unverified partial change to workflow safety gates.

## Origin

- **Created:** 2026-06-07
- **Session:** opencode:Issue #24520 review follow-up
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** — (standalone leaf for GH#24520)
- **Blocked by:** — none known
- **Conversation context:** Review of GH#24520 proved that org-owned reusable workflow callers are misclassified because workflow helpers hardcode `marcusquinn/aidevops` as the only trusted reusable workflow target. The review approved the issue but required a worker-ready TODO/brief before dispatch.

## What

Make managed workflow checking and syncing accept an explicitly configured reusable workflow repository/ref target while preserving the existing default behavior.

When a user configures an organization-owned reusable workflow repository such as `ORG/.github` with a reviewed SHA or branch ref, downstream caller workflows like:

```yaml
jobs:
  gate:
    uses: ORG/.github/.github/workflows/maintainer-gate-reusable.yml@1234567890abcdef1234567890abcdef12345678
```

must classify as `CURRENT/CALLER` when the rest of the caller shape matches the canonical template, and `sync-workflows` must render the same configured target. Unconfigured users must continue to get `marcusquinn/aidevops/.github/workflows/*-reusable.yml@main`.

## Why

Organizations route downstream repositories through org-owned reusable workflow repos for supply-chain control, auditability, pinned reviewed SHAs, and policy enforcement. Today the checker treats those canonical-shape callers as `NEEDS-MIGRATION` solely because the target repository identity is hardcoded. A permissive matcher would be unsafe; the fix must make the trusted target explicit and auditable.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — expect helper, template, tests, and config docs/reference updates.
- [ ] **Every target file under 500 lines?** No — both workflow helpers exceed 500 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — resolver/test design required.
- [ ] **No judgment or design decisions?** No — shared resolver, validation, and config precedence must be designed.
- [ ] **No error handling or fallback logic to design?** No — invalid config handling and default fallback required.
- [x] **No cross-package or cross-module changes?** Yes — all changes remain within aidevops workflow tooling/docs/tests.
- [ ] **Estimate 1h or less?** No — estimate ~4h.
- [ ] **4 or fewer acceptance criteria?** No — safety and regression coverage require more.
- [x] **Dispatch-path classification:** No self-hosting dispatch path files are in scope.

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file workflow tooling change with shell helper design and tests, but it follows existing `repos.json` per-repo config and runner injection patterns.

## PR Conventions

Leaf issue — PR body should use `Resolves #24520`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The validated issue/review already identifies the root cause and affected files. A partial draft touching workflow safety gates could anchor workers to unverified assumptions.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, duplicate/open-PR discovery, and file-ref verification completed against `origin/main` worktree HEAD `1d3b0715b` plus collision check noting unrelated TODO commit `59de4e903`.
- **Verification run:** `.agents/scripts/tests/test-check-workflows-helper.sh` and `.agents/scripts/tests/test-sync-workflows-helper.sh` were run during issue review and passed (12/12 and 28/28). Not rerun for this brief-only task.
- **Stale-assumption warning:** Re-check target files and open PRs before editing; workflow helpers are active surfaces and may change quickly.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/check-workflows-helper.sh` — replace hardcoded downstream target detection/normalization with configured expected reusable target resolution.
- `EDIT: .agents/scripts/sync-workflows-helper.sh` — render caller templates and runner injection against the same configured reusable target resolver.
- `EDIT: .agents/templates/workflows/*-caller.yml` — keep defaults usable, but ensure rendering can substitute both reusable repo and ref. At minimum verify `issue-sync-caller.yml`, `review-bot-gate-caller.yml`, `maintainer-gate-caller.yml`, and `loc-badge-caller.yml`.
- `EDIT: .agents/scripts/tests/test-check-workflows-helper.sh` — add classifier regressions.
- `EDIT: .agents/scripts/tests/test-sync-workflows-helper.sh` — add rendering/apply regressions.
- `EDIT: documentation/config reference as appropriate` — document `workflow_reusable_repo` and `workflow_reusable_ref` global/per-repo shape wherever `repos.json` fields are documented.
- `EDIT: TODO.md` and `NEW: todo/tasks/t3594-brief.md` are already present for this task.

### Current Evidence / Verified Anchors

- `.agents/scripts/check-workflows-helper.sh:157` currently normalizes refs only for `marcusquinn/aidevops/.github/workflows/${_reusable_escaped}`.
- `.agents/scripts/check-workflows-helper.sh:214` currently treats only `uses: marcusquinn/aidevops/.github/workflows/${_reusable_escaped}@` as a downstream caller.
- `.agents/scripts/sync-workflows-helper.sh:203` currently rewrites refs only for `uses: marcusquinn/aidevops/.github/workflows/...`.
- `.agents/scripts/sync-workflows-helper.sh:257` currently injects `runner:` only after a `uses:` line beginning with `marcusquinn/aidevops`.
- `.agents/templates/workflows/issue-sync-caller.yml:57` still ships default `uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@main`.
- Existing per-repo config pattern: `.agents/scripts/sync-workflows-helper.sh::_read_runner_field` reads `.initialized_repos[] | select(.slug == $s) | .runner`.
- Existing runner drift test pattern: `.agents/scripts/tests/test-sync-workflows-helper.sh:267-310` builds temporary repos, writes `repos.json`, runs helper, and asserts JSON/output.

### Implementation Steps

1. Add a shared target resolver in the workflow helpers.
   - Provide defaults: repo `marcusquinn/aidevops`, ref `main` or `@main` normalized internally to exactly one leading `@` at render time.
   - Read optional global config and per-repo override from `repos.json`. Suggested keys from GH#24520: `workflow_reusable_repo` and `workflow_reusable_ref`.
   - Per-repo override should win over global default; global default should win over built-in defaults.
   - Validate repo as `OWNER/REPO` with no whitespace/control chars. `ORG/.github` is valid and intentionally produces `ORG/.github/.github/workflows/...`.
   - Validate ref is non-empty and has no whitespace/control chars. Accept branch names, tags, and full SHAs. Do not require `main`.

2. Use the resolver everywhere caller identity is built or matched.
   - Build expected uses target as: `<resolved_repo>/.github/workflows/<reusable_file>@<resolved_ref>`.
   - Keep self-caller detection (`uses: ./.github/workflows/...`) unchanged for the aidevops repo.
   - In `check-workflows`, normalize refs only for the configured expected target. Do not normalize arbitrary matching filenames from other repositories.
   - In `sync-workflows`, render templates by replacing both the repo and ref in the canonical caller content before branch/runner injection.
   - Ensure runner injection matches the rendered `uses:` line regardless of repo name.

3. Keep trust boundaries strict.
   - Do **not** accept “any repo with the same reusable filename”.
   - Do **not** mark a caller current when it points to a repo/ref other than the configured target.
   - Preserve drift detection when the caller shape differs from canonical content even if the target repo/ref matches.
   - Preserve reusable-workflow update visibility: accepting a configured pinned ref must only suppress false caller-shape drift. It must not suppress checks that compare managed reusable workflow content/interface against the aidevops baseline and suggest updating copied/org-owned `*-reusable.yml` files when aidevops ships a newer compatible version.

4. Separate caller-target drift from reusable-content/update drift.
   - Caller target drift: the downstream `*-caller.yml` points at the expected configured repo/ref and has the canonical caller shape. A pinned SHA is allowed here.
   - Reusable content drift: an organization-owned repository may also carry copies of aidevops `*-reusable.yml`. `check-workflows` must still be able to identify that those reusable workflow files are older than the aidevops templates/baseline and report an update recommendation rather than hiding the update behind `CURRENT/CALLER`.
   - If the current helper only inspects downstream caller repos and cannot fetch/inspect the configured reusable repo, document that limitation and add the minimal safe signal: do not claim reusable workflows are current; surface that reusable repo update checking is unavailable/needs a configured local path or future fetch support.
   - Do not auto-update an org-owned reusable workflow repo unless it is the explicitly selected sync target and the normal `sync-workflows --apply` safety flow supports that repository. Suggest updates when direct mutation is outside scope.

5. Update tests.
   - Default upstream caller remains `CURRENT/CALLER`.
   - Configured org-owned caller (`ORG/.github/.github/workflows/issue-sync-reusable.yml@<sha>`) is `CURRENT/CALLER`.
   - Pinned SHA ref is accepted and not reported as drift merely because it is not `@main`.
   - Per-repo override wins over global default.
   - Caller pointing at an unconfigured repo remains `NEEDS-MIGRATION` or drifted/not current, not `CURRENT/CALLER`.
   - True local full-copy workflow still reports `NEEDS-MIGRATION`.
   - Drifted canonical-shape caller still reports `DRIFTED/CALLER`.
   - Older org-owned `*-reusable.yml` content is still reported as needing an update/suggestion when the helper has enough configured access to compare it.
   - `sync-workflows --apply` writes configured repo/ref and runner injection still works with non-default repo.

6. Update docs/comments where they describe the canonical target.
   - Public examples may use placeholders such as `ORG/.github` and `<reviewed-sha>`.
   - Do not include private repo names or local paths in public issue/PR bodies.

### Verification

Run from repo root:

```bash
.agents/scripts/tests/test-check-workflows-helper.sh
.agents/scripts/tests/test-sync-workflows-helper.sh
shellcheck .agents/scripts/check-workflows-helper.sh .agents/scripts/sync-workflows-helper.sh .agents/scripts/tests/test-check-workflows-helper.sh .agents/scripts/tests/test-sync-workflows-helper.sh
```

If documentation files change, run the repo markdown/documentation checks that normally cover those files, or state why not run.

## Acceptance Criteria

- [ ] Unconfigured behavior remains byte-compatible for downstream callers using `marcusquinn/aidevops/.github/workflows/*-reusable.yml@main` except intentional ref normalization.
- [ ] Configured global and per-repo `workflow_reusable_repo`/`workflow_reusable_ref` are honored by both check and sync paths.
- [ ] Pinned SHA refs are accepted for configured targets and do not cause false drift.
- [ ] Reusable workflow update checks remain visible: configured pinned caller refs do not hide older copied/org-owned `*-reusable.yml` content when comparison is possible, and limitations are explicitly reported when comparison is not possible.
- [ ] Unconfigured or mismatched third-party reusable workflow targets are not silently trusted.
- [ ] Existing runner override support still works for non-default reusable workflow repos.
- [ ] Regression tests and ShellCheck pass.

## References

- GH#24520 review comment approved the issue and identified root cause/affected lines.
- Related reusable workflow rollout context: GH#20649/GH#20662.
- Related pinned-input compatibility context: GH#22733.
- Related cross-account secret pass-through context: GH#20976.
