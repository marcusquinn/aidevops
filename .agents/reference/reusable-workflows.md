<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Reusable workflows architecture

aidevops ships GitHub Actions workflow logic as **reusable workflows** (`on: workflow_call:`) rather than copying workflow YAMLs into every downstream repo. This eliminates drift as an architectural class — the logic lives in one place; downstream repos consume it via tiny caller YAMLs.

## Why this pattern

The old model (replicated workflows + replicated framework scripts per repo) caused three chronic problems:

| Problem | Observed | Root cause |
|---|---|---|
| Workflow YAML drift | GH#20637 (stale `issue-sync.yml` missing t2385 fix in downstream) | No propagation mechanism from aidevops to downstream copies |
| Framework script drift | `really-simple-ssl-multisite` had 3 drifted `.agents/scripts/` files | Scripts shipped per-repo, no sync |
| Silent workflow failures | `awardsapp` + `compressx-multisite` had workflow YAML but no `.agents/scripts/` | Workflow referenced scripts that didn't exist |

The reusable pattern solves all three at once:

- One source of truth for workflow logic (`aidevops/.github/workflows/*-reusable.yml`)
- Framework scripts fetched at runtime via `actions/checkout` — downstream repos need **zero** `.agents/scripts/` files
- Caller YAMLs are ~45 lines each, mostly event-trigger declarations — the surface area for drift is minimal and declarative

## Migrated workflows

| Workflow file | Reusable | Downstream template | Migrated |
|---|---|---|---|
| `issue-sync.yml` | `issue-sync-reusable.yml` | `issue-sync-caller.yml` | t2770 (PR #20662) |
| `review-bot-gate.yml` | `review-bot-gate-reusable.yml` | `review-bot-gate-caller.yml` | GH#20727 |
| `maintainer-gate.yml` | `maintainer-gate-reusable.yml` | `maintainer-gate-caller.yml` | GH#21154 |

## Architecture

```
aidevops repo (source of truth):
  .github/workflows/issue-sync-reusable.yml       ← on: workflow_call:
                                                     All jobs. All logic. 1300+ lines.
  .github/workflows/issue-sync.yml                ← thin caller for aidevops's own CI
                                                     (uses: ./.github/workflows/issue-sync-reusable.yml)
  .github/workflows/review-bot-gate-reusable.yml  ← on: workflow_call: (GH#20727)
                                                     All gate logic. Helper runtime-fetched.
  .github/workflows/review-bot-gate.yml           ← thin caller for aidevops's own CI
                                                     (uses: ./.github/workflows/review-bot-gate-reusable.yml)
  .github/workflows/maintainer-gate-reusable.yml  ← on: workflow_call: (GH#21154)
                                                     All 5 gate jobs. Self-contained (no helper scripts).
                                                     Layer 1 of the GH#17671 defense-in-depth.
  .github/workflows/maintainer-gate.yml           ← thin caller for aidevops's own CI
                                                     (uses: ./.github/workflows/maintainer-gate-reusable.yml)
  .agents/templates/workflows/
    issue-sync-caller.yml                         ← canonical downstream template (issue-sync)
    review-bot-gate-caller.yml                    ← canonical downstream template (review-bot-gate)
    maintainer-gate-caller.yml                    ← canonical downstream template (maintainer-gate)
  .agents/scripts/issue-sync-helper.sh            ← framework shell (source of truth)
  .agents/scripts/review-bot-gate-helper.sh       ← gate helper (source of truth, GH#20727)
  .agents/scripts/shared-constants.sh
  .agents/scripts/issue-sync-lib.sh

downstream repo (thin callers):
  .github/workflows/issue-sync.yml                ← ~45 lines, declares triggers,
                                                     uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@<ref>
  .github/workflows/review-bot-gate.yml           ← ~50 lines, declares triggers + concurrency,
                                                     uses: marcusquinn/aidevops/.github/workflows/review-bot-gate-reusable.yml@<ref>
  .github/workflows/maintainer-gate.yml           ← ~45 lines, declares triggers + permissions ceiling,
                                                     uses: marcusquinn/aidevops/.github/workflows/maintainer-gate-reusable.yml@<ref>
  (no .agents/scripts/ needed — maintainer-gate is self-contained; issue-sync/review-bot-gate fetched via __aidevops/)
```

### How a run flows

1. Event fires in downstream repo (e.g. a PR is merged).
2. GitHub runs the caller workflow; `jobs.sync.uses` points at the aidevops reusable workflow.
3. GitHub fetches the reusable workflow from `marcusquinn/aidevops` at the specified ref.
4. Each job in the reusable workflow runs with `github.event_name` reflecting the caller's event (so the `if: github.event_name == 'push'` guards work correctly across repos).
5. First step in each job: `actions/checkout` of the caller's repo (so the sync helpers see the caller's `TODO.md`, `todo/`, etc.).
6. Second step: `actions/checkout` of `marcusquinn/aidevops` into `__aidevops/` (so `bash __aidevops/.agents/scripts/...` finds the framework scripts).
7. Subsequent steps run the sync helpers against the caller's repo files.

This pattern also works when aidevops calls its own reusable workflow (same-repo use), at the cost of a ~2s secondary checkout. The uniformity (one code path for all callers) is worth it.

## Pinning strategies

The caller declares which version of aidevops to fetch via the `@ref` suffix on `uses:`:

| Pin | Behaviour | When to use |
|---|---|---|
| `@main` | Always runs the latest aidevops code | Default for personal/small-team repos; picks up fixes automatically |
| `@v3.9.0` | Runs a specific aidevops version | Production/critical repos where you want to test before upgrading |
| `@<sha>` | Runs an exact commit | Highest stability, must be updated manually for every fix |

The canonical caller template (`.agents/templates/workflows/issue-sync-caller.yml`) uses `@main` by default. To pin, edit the caller YAML in the downstream repo:

```yaml
jobs:
  sync:
    uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@v3.9.0
    #                                                                   ^^^^^^^
    #                                                                   change this
    secrets:
      SYNC_PAT: ${{ secrets.SYNC_PAT }}
```

Keep pinned callers in sync with aidevops releases via:

```bash
aidevops check-workflows        # detect drift
aidevops sync-workflows --apply # update pins to current aidevops version
```

See also [`auto-dispatch.md`](auto-dispatch.md) for the `SYNC_PAT` requirement (unchanged under the reusable pattern — still per-repo secret).

## Security model

- **`secrets: inherit` only works within the same GitHub account/org (GH#20976).** Cross-account callers (every downstream user — `marcusquinn/aidevops` is the only same-account consumer) receive empty values for caller-repo secrets when using `secrets: inherit` against a reusable workflow in a different account. Explicit secret pass-through is required:

  ```yaml
  # CORRECT for cross-account consumers (canonical template uses this):
  jobs:
    sync:
      uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@main
      secrets:
        SYNC_PAT: ${{ secrets.SYNC_PAT }}

  # BROKEN for cross-account consumers (SYNC_PAT resolves to empty):
  jobs:
    sync:
      uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@main
      secrets: inherit   # ← only works within the same account/org
  ```

  The canonical caller templates (`issue-sync-caller.yml`, `loc-badge-caller.yml`) use explicit pass-through. `review-bot-gate-caller.yml` and `maintainer-gate-caller.yml` keep `secrets: inherit` because they only reference `secrets.GITHUB_TOKEN` internally — `GITHUB_TOKEN` is always provided by the runner and is unaffected by the cross-account limitation.

  If a new user-defined secret is added to a reusable workflow's `secrets:` input block, the matching caller template MUST also add it as an explicit `secrets: MySecret: ${{ secrets.MySecret }}` entry. This is the enumeration trade-off of explicit pass-through — adding a new optional secret upstream requires a template bump + `aidevops sync-workflows --apply` on consumers. It is preferable to silently broken cross-account inherit.

  **Symptom of the cross-account bug**: `gh secret list` shows `SYNC_PAT` set and recent, but the workflow's `Check SYNC_PAT visibility` step logs `SYNC_PAT_PRESENT:` (empty). Fix: `aidevops sync-workflows --apply`.

- **Referencing `@main` is a trust boundary.** You're trusting whoever controls aidevops's `main` branch. For higher-trust deployments, pin to a version tag (`@v3.9.0`) and update explicitly.
- **`pull_request_target` vs `pull_request`.** The reusable workflow's job guards accept either event type. The caller picks based on its security model:
  - **Private repo with trusted contributors**: `pull_request` is simpler and has fewer footguns.
  - **Public repo accepting external PRs**: `pull_request_target` is required if the workflow needs write permissions or secrets (but bring standard `pull_request_target` hygiene — don't check out the PR's head code if you trust it to run with elevated privileges).
- **`default_workflow_permissions: read` repos (GH#20967).** GitHub's recommended security default is `default_workflow_permissions: read`. Reusable workflow job-level `permissions:` declarations cannot exceed the CALLER's ceiling — they are capped at whatever the caller workflow grants. A caller with no `permissions:` block inherits the repo's restrictive default, so GitHub refuses to create any jobs (`conclusion: startup_failure`, zero jobs). The canonical caller templates include a top-level `permissions:` block that is the union of all job-level permissions used by the reusable workflow. If you add a new permission to a reusable workflow job, also update the matching caller template.

  Verification: `gh api repos/OWNER/REPO/actions/permissions/workflow --jq .default_workflow_permissions` returns `"read"` or `"write"`. A `"read"` repo will fail without the caller's `permissions:` block.

## Framework self-test assumption guard

Both GH#20967 (missing `permissions:` block) and GH#20976 (`secrets: inherit` cross-account failure) share the same root cause class: the canonical caller templates were authored against the framework's own self-test scenario (`marcusquinn/aidevops` calling itself) which has same-account and same-repo semantics that don't hold for downstream consumers.

When authoring or reviewing a canonical caller template, apply this checklist to catch the pattern before it ships:

| Check | Self-test passes? | Downstream breaks? | Gate |
|---|---|---|---|
| `secrets: inherit` for user-defined secrets | Yes (same-account) | Yes (cross-account empty) | Always use explicit `secrets: MySecret: ${{ secrets.MySecret }}` for user-defined secrets |
| Missing `permissions:` block | Yes (`default_workflow_permissions: write` on framework repo) | Yes (`startup_failure` on read-default repos) | Always include a top-level `permissions:` block with the union of all job-level permissions |
| Hardcoded `marcusquinn` org references | Yes (same repo) | Possible (wrong org) | Use `github.repository_owner` or `inputs:` for org-specific values |

This checklist lives here so the next "framework self-test passes, downstream broken" instance surfaces during template authoring, not after a downstream user files a bug report.

## Migration: from copied workflow to caller

If a downstream repo currently carries a full copy of `issue-sync.yml` (pre-Phase 3 pattern), migrate it to the caller pattern:

```bash
# Option A: CLI-assisted (after Phase 2 lands)
aidevops sync-workflows --apply

# Option B: Manual
cd ~/Git/downstream-repo
git checkout -b chore/migrate-to-reusable-workflow
cp ~/Git/aidevops/.agents/templates/workflows/issue-sync-caller.yml \
   .github/workflows/issue-sync.yml
git rm -rf .agents/scripts/  # no longer needed — fetched at runtime
git add -A
git commit -m "chore: migrate issue-sync to aidevops reusable workflow

Was: 1331 lines of replicated workflow logic + 3 framework scripts.
Now: ~45-line caller; aidevops reusable workflow runs the logic.
Fixes drift by design (single source of truth upstream).

Ref marcusquinn/aidevops#20662"
```

After migration: run `aidevops check-workflows` in the aidevops repo to verify the caller matches the canonical template.

## Adding new framework workflows

To make a new aidevops workflow reusable by downstream repos:

1. Author the logic in `.github/workflows/<name>-reusable.yml` with `on: workflow_call:`.
2. Add a thin caller for aidevops itself at `.github/workflows/<name>.yml` using `uses: ./.github/workflows/<name>-reusable.yml`.
3. Add a canonical template at `.agents/templates/workflows/<name>-caller.yml` using `uses: marcusquinn/aidevops/.github/workflows/<name>-reusable.yml@main`. Include a top-level `permissions:` block that is the union of all job-level permissions declared in the reusable workflow — callers for repos with `default_workflow_permissions: read` cannot create any jobs without this (GH#20967).
4. If the workflow depends on framework scripts, ensure each job includes an `actions/checkout` of `marcusquinn/aidevops` into `__aidevops/` before invoking those scripts. Reference scripts via `__aidevops/.agents/scripts/...`.
5. Update `aidevops check-workflows` manifest to include the new template name (Phase 1 helper).
6. Run `aidevops sync-workflows` to propagate to repos that have the predecessor workflow.

## References

- PR [#20662](https://github.com/marcusquinn/aidevops/pull/20662) — Phase 3 implementation (issue-sync migration)
- Issue [#20637](https://github.com/marcusquinn/aidevops/issues/20637) — the symptom report that surfaced the drift class
- Issue [#20648](https://github.com/marcusquinn/aidevops/issues/20648) — Phase 1 drift detector
- Issue [#20649](https://github.com/marcusquinn/aidevops/issues/20649) — Phase 2 opt-in resync
- Issue [#20727](https://github.com/marcusquinn/aidevops/issues/20727) — review-bot-gate migration (SHA-pin stale drift)
- Issue [#20967](https://github.com/marcusquinn/aidevops/issues/20967) — missing `permissions:` block in caller template (sister bug, same root cause class)
- Issue [#20976](https://github.com/marcusquinn/aidevops/issues/20976) — `secrets: inherit` fails cross-account; canonical template switched to explicit pass-through
- Issue [#21154](https://github.com/marcusquinn/aidevops/issues/21154) — maintainer-gate migration (layer-1 defense-in-depth propagation)
- Reference [incident-gh17671-supply-chain.md](incident-gh17671-supply-chain.md) — postmortem that motivated maintainer-gate propagation
- GitHub docs: [Reusing workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
