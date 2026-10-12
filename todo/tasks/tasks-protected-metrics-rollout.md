<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Planning-only: protected repository metrics downstream rollout

## Status and authority

Saved for later on 2026-10-12. The operator accepted an offer to capture a
follow-up brief for a reusable downstream rollout checklist. This capture does
not start checklist implementation, dispatch a worker, or authorize downstream
repository writes, credential provisioning, policy changes, or live experiments.
The ID-less Backlog entry stays local to repository planning; no automatic issue
dispatch is requested.

## Pre-flight

- [x] Memory recall: repository metrics downstream rollout checklist → no hits.
- [x] Discovery: local TODO/plans and GitHub issue searches found no matching
  rollout checklist. The completed publisher fix is a prerequisite, not a
  duplicate task; no open related PR was returned by prework discovery.
- [x] File references: the nine existing paths below are tracked at
  `16ec7fc8c3a126a9d933fe5f2bbd26fecf18a539`.
- [x] Tier: standard for future documentation synthesis within the already
  decided safety boundary; live execution requires scoped operational readiness.
- [x] Seeded draft PR: skipped; this is saved planning, not implementation.

## What and why

Prepare a reusable checklist for upgrading existing downstream metrics callers
and validating protected-branch publication. It must distinguish artifact
generation, a queued candidate PR, terminal-success required checks, and an
actually merged update. A green publisher run must not imply metrics reached
the protected default branch.

The implementation shipped in v3.39.24 with local Git regression coverage and
successful release/postflight verification. Live private-repository/PAT
end-to-end behavior was explicitly not exercised. Existing callers also need
permission upgrades, and job-token-created PR events may suppress Actions
triggers. This follow-up closes that operational documentation/evidence gap;
it must not reimplement the publisher or assume the gap is a proven defect.

## Observed evidence

- Original issue: https://github.com/marcusquinn/aidevops/issues/34480
- Implementation: https://github.com/marcusquinn/aidevops/pull/34484
- Release: https://github.com/marcusquinn/aidevops/releases/tag/v3.39.24
- Delivery and limitations:
  https://github.com/marcusquinn/aidevops/issues/34480#issuecomment-6117460369
- Publication succeeded:
  https://github.com/marcusquinn/aidevops/actions/runs/38200955821
- Exact-tag postflight succeeded:
  https://github.com/marcusquinn/aidevops/actions/runs/38201241842
- Prior focused results: publisher 30 assertions, SYNC_PAT detection 28,
  reusable permission contracts 16, workflow-install regression 16. These are
  historical results, not a live downstream-validation claim.

## Reference patterns and complete write surface

Read these existing paths before drafting or executing:

- `.agents/aidevops/badges.md`: permission ceiling, helper pinning, PR/check
  semantics, and bot-author/skip-ci loop prevention.
- `.agents/reference/sync-pat-platforms.md`: minimum credential scope and
  protection-preserving fallback guidance.
- `.agents/templates/workflows/loc-badge-caller.yml`: intended downstream caller
  shape, cross-account secret forwarding, triggers, and pin coupling.
- `.github/workflows/loc-badge-reusable.yml`: workflow permissions, exact helper
  SHA resolution, generation, and publisher invocation.
- `.agents/scripts/repo-metrics-git-push-helper.sh`: GH006-only fallback,
  ownership validation, bounded retries, and stale-scan protection.
- `.agents/scripts/tests/test-repo-metrics-git-push-helper.sh`: existing local Git
  behavior checks, including preserving extra branch history.
- `.agents/scripts/tests/test-sync-pat-detection.sh`: credential advisory checks.
- `.agents/scripts/tests/test-reusable-workflow-permission-contracts.sh`: caller
  and reusable-job permission contracts.
- `.agents/scripts/tests/test-loc-badge-reusable-install.sh`: workflow delegation
  and untracked generated-artifact detection.

Future documentation surface: add a rollout section/pointer in
`.agents/aidevops/badges.md`; use a dedicated
`.agents/reference/repository-metrics-rollout.md` only if needed to keep detailed
steps out of the owning guide. No publisher, schema, generated metrics, test,
dependency, or root CI changes are implied. Deployed framework copies remain
generated from repository source, not hand-edited.

The downstream slug, checkout, caller filename, default branch, required check
names, helper-mirror identity, and approved test target are not yet known. Discover
them from the selected repository instead of inventing paths or copying private
identifiers into this public plan. Actual live writes are limited to a separately
scoped caller-upgrade PR and generated metrics PR/artifacts on that selected
target; no fleet-wide mutation or repository creation is authorized here.

## Checklist content to produce later

1. Inventory the real caller, including nonstandard filenames. Resolve its
   workflow/helper pins to the same verified release commit, and retain the
   repository's actual default branch, custom outputs, and trigger policy.
2. Compare caller and reusable-job permissions. The metrics job needs
   `actions: read`, `contents: write`, and `pull-requests: write`; preserve
   read-only defaults elsewhere. An old caller cannot be elevated by the
   reusable workflow. If a private helper mirror is used, verify explicit
   repository/ref coupling and read-token visibility without revealing tokens.
3. Choose the existing authorized route: job-token PR creation first; only when
   needed, a repository-scoped fine-grained SYNC_PAT with Contents and Pull
   requests read/write for the bounded PR API fallback. Never propose broad
   tokens, credential export, or a default-branch protection bypass.
4. Record the target's legitimate required-check trigger mechanism before
   publishing a job-token-created candidate. If required checks do not execute,
   leave the PR queued and record the gap; do not approve, merge, or count absent
   checks as passing.
5. Verify one deterministic `aidevops/repository-metrics` PR is created/updated
   with only configured generated artifacts. A second refresh must update the
   same PR; an unrelated/extra-history branch must remain untouched.
6. Preserve loop prevention: branch candidate commits omit skip-ci, the eventual
   squash subject retains it, bot-author filtering and output path exclusions
   stay intact. A superseded scan must not overwrite newer artifacts.
7. Explain safe rollback and cleanup: revert only the rollout-owned caller
   changes through normal review; close an unmerged test candidate only with
   target-owner authority. Do not force-delete or rewrite unrelated work. Keep
   original protection and Actions settings unchanged.

## Live validation matrix — gated, not performed

Use an already-approved isolated target and existing credentials only. Obtain
specific authority before changing target settings, adding secrets, creating a
repository, or intentionally inducing failures. Unavailable cases stay
`unverified` with a resume condition, not `passed`.

| Case | Evidence and expected outcome |
| --- | --- |
| Unprotected target | Direct publication succeeds, only generated files change, and no fallback PR appears. |
| Protected target; Actions PR creation permitted | GH006 yields exactly one candidate PR; protection remains enforced; required checks execute through the target's authorized mechanism before any merge. |
| Protected target; job-token PR creation unavailable; scoped PAT already configured | The logs show one bounded PAT API retry, exactly one PR, and no protection bypass or secret exposure. |
| Protected target; no usable PR credential path | The run fails with actionable permission guidance, unless warning-only mode was explicitly selected; no merged-publication claim is made. |
| Private helper mirror already available | Workflow and helpers resolve to the intended coupled ref; read credentials are present only through the approved secret store. |
| Repeat/concurrent refresh or existing extra branch history | The same candidate is updated or creation is recovered without duplicate PRs; unrelated history is preserved. Prefer existing local tests for intentionally destructive/racy negatives. |

For each exercised case retain run/PR links, exact source/head/ref identities,
artifact-only diff, terminal required-check evidence, before/after policy
comparison, and redacted diagnostics. Keep private identities and reports in
the approved private evidence location; publish only sanitized conclusions.

## Hazards and compatibility

- Mixed versions: upgrade caller permissions and coupled pins together through
  normal review; do not deploy a new reusable job behind an old permission ceiling.
- Retry/partial success: recover an already-created PR before retrying. Do not
  repeat publication commands blindly or expand the one-PAT-attempt contract.
- Concurrency: inspect ownership and source ancestry; never discard extra branch
  history to make a refresh succeed.
- Credentials and event suppression: a supplied PAT is not bypass authority;
  successful PR API creation is not proof required checks were triggered.
- Rollback: preserve existing policies, unrelated secrets/workflows, and normal
  review. No new runner, mock system, test-only interface, or live harness is
  required by this documentation task.

## Verification before future execution

Revalidate the released behavior and existing contracts with scoped checks:

```bash
bash .agents/scripts/tests/test-repo-metrics-git-push-helper.sh
bash .agents/scripts/tests/test-sync-pat-detection.sh
bash .agents/scripts/tests/test-reusable-workflow-permission-contracts.sh
bash .agents/scripts/tests/test-loc-badge-reusable-install.sh
git diff --check
```

For documentation changes use existing changed-file Markdown/secret lint, not a
new test framework or blanket repository scan. Review the target's ordinary
Actions/PR path for live evidence; local tests alone cannot satisfy live cases.

## Acceptance criteria for the future follow-up

- [ ] One concise reusable checklist covers inventory, coupled pins, minimum
  caller permissions, credential readiness, required-check triggering, rollback,
  and publication-state distinctions.
- [ ] Positive direct/protected publication paths have either linked live proof
  from an authorized target or an explicit unverified status and wake condition.
- [ ] Negative guarantees cover no protection bypass, no secret leakage, no
  duplicate PRs, no unrelated-history replacement, and no stale snapshot overwrite.
- [ ] Existing checks verify unchanged publisher/permission contracts; no new
  test infrastructure or fleet-wide writes are introduced by default.
- [ ] Live evidence never claims a candidate is merged merely because generation
  or PR creation succeeded, and missing required checks remain blocking.

## Next action and recovery

When this saved follow-up is explicitly picked up, re-read the owning guide and
current publisher, deduplicate again, then draft the checklist first. Before
live execution, resolve the exact target and its operational authority/context.
If access, credentials, or check triggering is unavailable, stop only that case,
record the evidence and exact resume condition, and continue safe documentation.
This captured brief itself is the current deliverable; the unchecked future
criteria above are intentionally not implemented or dispatched.
