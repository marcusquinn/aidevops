<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-12
- **Created by:** ai-interactive (requested by the maintainer)
- **Parent task:** none
- **Conversation context:** A signing audit on 2026-11-12 found that every Cloudron package release has Sigstore attestations for the image and the `CloudronVersions.json` bytes. The `chore: publish Cloudron package <version> [skip ci]` commit and its `v*` tag are unsigned, so GitHub labels those commits "Unverified". The maintainer asked for signed publish commits.

## What

Make catalog publication produce a GitHub-verified ("Verified") publish commit on `main`. The workflow must keep its current guarantees: the commit and new tag land together or not at all, only `CloudronVersions.json` changes, the `Cloudron-Source:` trailer stays, the docs-only rebase retry still works, and attestations still verify.

## Why

Live audit (2026-11-12): latest releases of `cloudron-netbird-app` v2.7.3, `aidevops-cloudron-app` v0.1.45, `cloudron-buzz-app` v0.1.28, `cloudron-headscale-app` v0.1.5, `cloudron-nostr-relay-app` v0.1.4, `cloudron-librecrawl-app` v0.1.9, `cloudron-opendesk-app` v0.2.22, `cloudron-warmbly-app` v0.1.8 and `cloudron-orbit-app` v0.1.0 all have `commit.verification.verified=false` and lightweight tags. Their catalog attestations exist (1 each). Install integrity is already covered by the image digest and attestations, so this is low priority. It removes "Unverified" labels from release history and lets anyone check the publish commit's origin without attestation tooling.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Changes a release workflow's trust-boundary push step (`# aidevops:trust-boundary`, `.github/workflows/cloudron-catalog-publish-reusable.yml:319`). The design must preserve atomicity and the retry path, and depends on GitHub API signing behaviour that must be verified first.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/cloudron-catalog-publish-reusable.yml:301-345` ("Commit catalog and push tag atomically") — create the publish commit through the GitHub API so GitHub signs it, then publish commit and tag together.
- `EDIT: .github/workflows/cloudron-catalog-publish-reusable.yml:362-411` (release repair job) only if the new commit shape changes what `git rev-list --parents`, the `Cloudron-Source` trailer read or `git diff-tree` see. Keep these checks passing for both old and new tags.
- `EDIT: .agents/tools/deployment/cloudron-app-publishing-skill.md` — one sentence in the publication section saying publish commits are GitHub-signed and how to check (`gh api repos/OWNER/REPO/commits/vX.Y.Z --jq .commit.verification`).
- Tests: whichever tests in `.agents/scripts/tests/` assert this workflow's push step text (search with `rg -n 'push --atomic' .agents/scripts/tests`). The current matches are `test-cloudron-package-monitor.sh` and `test-task-publication-worker.sh`; confirm each is actually about this workflow before editing.

### Complete Write Surface

- **Callers/readers:** every managed `cloudron-catalog-publish.yml` caller in package repositories (pinned by `aidevops_ref`), `cloudron-package-release-lib.sh`, `cloudron-release-approval-helper.sh`.
- **Writers/mutation paths:** the publish job's push to `refs/heads/main` and `refs/tags/v<version>`.
- **Existing verification/tests:** `.agents/scripts/tests/test-cloudron-release-evidence.py`, `test-cloudron-release-approval.sh`, plus whatever the search above finds.
- **Schemas/config:** N/A because catalog format is unchanged.
- **Generated/deployed mirrors:** package callers adopt the change when their `aidevops_ref` pin is bumped; no mass update is needed.
- **Migrations/backfills:** N/A because existing unsigned tags stay; tags are immutable by ruleset.
- **Cleanup/rollback paths:** callers pinned to the previous `aidevops_ref` keep the current behaviour.

### Implementation Steps

1. **Verify signing behaviour first (no guessing):** use Context7 or GitHub docs to confirm which API path produces `verification.verified=true` for the token in use: the job token, or `CLOUDRON_RELEASE_PAT` when branch rules require it. Candidates are REST `POST /repos/{owner}/{repo}/git/commits` without custom author/committer, and GraphQL `createCommitOnBranch`. Record the cited source in the PR.
2. **Preferred design (keeps atomic push):** create the signed commit object via the API with parent = current `main` head and a tree containing only the new `CloudronVersions.json`. Then rebuild that exact object locally from `GET /repos/{owner}/{repo}/git/commits/{sha}`, adding the `gpgsig` header from `verification.signature` to `verification.payload`. Write it with `git hash-object -t commit -w --stdin`, assert the hash equals the API SHA, tag it, and keep the existing `git push --atomic origin <sha>:refs/heads/main refs/tags/v$VERSION`. If the local hash cannot be made to match, fall back to step 3.
3. **Fallback design:** create the tag ref first, then fast-forward `main` via `PATCH /git/refs/heads/main` with `force: false`. If the branch update fails, delete the just-created tag (allowed: the tag ruleset blocks deletion, so this needs explicit evaluation; if impossible, do not use this design). Prefer reporting the blocker over weakening atomicity.
4. Keep the retry path: on a non-fast-forward, recreate the commit on the new `origin/main` after the same docs-only path check (`:330-335`), with the same catalog bytes and trailer.
5. Commit message unchanged, including the `Cloudron-Source:` trailer and `[skip ci]`.

### Hazards and Compatibility

- **Concurrency/atomicity:** commit and tag must never diverge; a tag without its catalog commit on `main` breaks the release repair job (`:369`).
- **Migration/rollback:** pinned callers are unaffected until their `aidevops_ref` moves.
- **Mixed-version/backward compatibility:** the release repair job must accept both old (unsigned) and new (signed) tags.
- **Idempotency/retry:** a rerun after partial API work must not create a second tag; reuse an existing unreferenced commit only if its tree and parent match.
- **Partial failure/recovery:** API commit creation without a ref update leaves only an unreferenced object, which is harmless.

### Complexity Impact

- **Target function:** inline workflow `run:` block (not a shell function). Keep new logic in a small helper script if it exceeds ~40 lines, e.g. `NEW: .agents/scripts/cloudron-signed-commit-helper.sh`, called from the workflow with the same pinned checkout the workflow already uses for helpers.
- **Action required:** shellcheck any new script; no function over 100 lines.

### Verification Before Dispatch

```bash
actionlint .github/workflows/cloudron-catalog-publish-reusable.yml
shellcheck .agents/scripts/cloudron-signed-commit-helper.sh   # if created
python3 .agents/scripts/tests/test-cloudron-release-evidence.py
bash .agents/scripts/tests/test-cloudron-release-approval.sh
```

- **Surface mapping:** actionlint covers workflow syntax; the existing release tests cover evidence and approval. Signing behaviour is proven by the cited docs plus one real publication. After merge, the next real upstream release on any package, with its caller pin bumped, must show `commit.verification.verified=true` and `gh attestation verify` still passing. Do not trigger a publication only to test this.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not trigger real publications; do not bump package versions or edit any `CloudronVersions.json`; do not add bypass actors or change rulesets; do not weaken attestation checks; do not bump package callers' `aidevops_ref` pins in this PR.

**AI brief owner:** the maintainer's interactive session that filed this issue.

### Files Scope

- `.github/workflows/cloudron-catalog-publish-reusable.yml`
- `.agents/scripts/cloudron-signed-commit-helper.sh`
- `.agents/tools/deployment/cloudron-app-publishing-skill.md`
- `.agents/scripts/tests/test-cloudron-release-evidence.py`
- `.agents/scripts/tests/test-cloudron-package-monitor.sh`

## Acceptance Criteria

- [ ] The publish step creates its commit through a cited GitHub API path that yields `commit.verification.verified=true`, and commit plus tag still land atomically.
- [ ] Commit content is unchanged: only `CloudronVersions.json`, same message and `Cloudron-Source:` trailer, and the docs-only rebase retry still works.
- [ ] Regression guard: the release repair job accepts both pre-change and post-change tags, attestation verification is unchanged, and the existing Cloudron release tests pass.

## Context & Decisions

- Install integrity is already enforced by the image digest and Sigstore attestations; this task is about visible commit provenance, hence `priority:low`.
- Tag signing is out of scope: GitHub does not sign API-created tag objects, and the tag ruleset already makes published tags immutable.
