---
name: cloudron-app-publishing
description: "Distribute Cloudron apps via CloudronVersions.json version catalogs"
mode: subagent
imported_from: external
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudron App Publishing

Distribute Cloudron apps independently using a `CloudronVersions.json` version catalog. Users add the file's URL in their dashboard or install via `cloudron install --versions-url <url>`.

## Quick Reference

- **Docs**: [docs.cloudron.io/packaging/publishing](https://docs.cloudron.io/packaging/publishing)
- **Upstream skill**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-app-publishing`)
- **Prerequisite**: Each version needs a registry-hosted image, normally built with `cloudron builder login` → `cloudron builder build`; on-server builds cannot be published
- **Last upstream review**: `74e455bd03f5`; adopted registry builder and explicit version-image selection guidance
- **Key file**: `CloudronVersions.json` — version catalog hosted at a public URL
- **Listing**: [Cloudron Community Apps](https://ca.cloudron.io) accepts a public versions URL after the catalog contains a tested release; listing is optional
- **Forum**: announce published community packages in [Community Apps (220)](https://forum.cloudron.io/category/220/community-apps); ask packaging questions in [App Packaging & Development (96)](https://forum.cloudron.io/category/96/app-packaging-development)

## Workflow

Keep these states distinct: **upstream detected** (a monitor finding),
**package prepared** (manifest and changelog updated), **image build verified**
(immutable Docker sources resolve and a no-push build succeeds), and **catalog
published** (a reviewed image is present in `CloudronVersions.json`). Detection
does not authorize any later state.

### Publication boundary: signed managed releases

For managed catalog packages, use **upstream detected → release PR ready →
release approval requested → approved → published**. After package tests,
`preflight-release` and green PR preflight (including the no-push image build),
run `cloudron-release-approval-helper.sh request <repo> <pr>`; do not merge.
The helper holds the PR and creates a version-deduplicated release issue with
the exact PR head, versions, changelog and evidence. `release-approval-required`
is a dedicated signed gate, not `needs-maintainer-review`. The approval-only
issue carries `no-auto-dispatch`; older unsigned requests are superseded.

The maintainer runs only `sudo aidevops approve issue <N> <repo>`. Routine `r924`
processes these issues every 30 minutes, requiring `VERIFIED` from
`approval-helper.sh verify issue <N> <repo> --require-authority`, the unchanged
head and green checks. It removes only its release hold and uses the normal
full-loop merge gates. A changed head requires an updated issue and new signed
approval. API/verification failures never authorize a merge.

For an interactive continuation authorized for one release, use
`cloudron-release-approval-helper.sh process --repo <slug> --issue <N> --apply`.
Omit `--apply` to preview the same scope without merging or publishing. `--repo`
still requires a registered, maintained Cloudron package and admin/maintain
permission; `--issue` selects only that approval issue number. Issue numbers are
repository-local, so use both filters for a single release. Unscoped `process`
(or `process --apply`) retains the routine default: all approval issues in all
registered maintained Cloudron package repositories. Keep the full repos registry;
no temporary `AIDEVOPS_REPOS_FILE` override is needed for scoping.

After merge, the existing main catalog workflow owns publication. The routine
waits boundedly and resumes verification later, then closes with evidence only
when the catalog version, version tag and non-draft GitHub release all exist.
GH#35649's workflow and upstream monitor own catalog-race recovery. Approval
never enables publication, changes credentials/protection, deploys an app, or
authorizes unrelated publication. See `cloudron-app-packaging.md` **Managed
Package Lifecycle** for the complete operator contract.

```bash
cloudron versions init  # creates CloudronVersions.json + DESCRIPTION.md, CHANGELOG, POSTINSTALL.md (edit all placeholders)
cloudron builder login  # authenticate with the Container registry app
cloudron builder build  # build and push image; remembers the repository
cloudron versions add --last-build --state testing  # record the last builder image without exposing it as stable
cloudron versions update --version=1.0.0 --state=published
# host CloudronVersions.json at a public URL
```

`cloudron versions init` also adds missing publishing fields to `CloudronManifest.json` with placeholder values. Edit all placeholders and scaffolded files before adding a version.

## Repository Baseline

Commit these before the first registry build:

- `CloudronVersions.json` initialized as `{ "stable": true, "versions": {} }`; never fabricate an entry before a real registry image exists.
- `CloudronManifest.json` publishing metadata: `id`, `title`, `author`, `description`, `tagline`, `version`, `website`, `contactEmail`, `iconUrl`, `packagerName`, `packagerUrl`, non-empty `tags`, non-empty `mediaLinks`, `changelog`, and `minBoxVersion` of at least `9.1.0`. Add `packageUrl` when the listing must link to the package source repository; this requires `minBoxVersion` 10.0.0.
- A local square 256×256 PNG icon (`icon` normally points to it) and at least one privacy-reviewed product screenshot or hero. `mediaLinks` must use public HTTPS URLs; Cloudron recommends a 3:1 layout such as 1200×400, rendered at 2× (2400×800) for high-density screens.
- A Cloudron-format changelog file when using `file://`: each release heading must be exactly `[X.Y.Z]`, because `cloudron versions add` does not parse Keep a Changelog headings such as `## [X.Y.Z]`. One file is enough: the aidevops release validator and preparation helper read the repository-relative `file://` path from the manifest's `changelog` field and preserve its heading format. Without a `file://` value, they fall back to `CHANGELOG.md`.
- A short publishing runbook that records the canonical catalog URL, registry/repository ownership, asset provenance, test install, rollback, and Community Apps listing steps without storing credentials.
- A managed GitHub Actions release workflow that creates and verifies keyless provenance for the immutable image digest and exact generated `CloudronVersions.json`; use `templates/workflows/cloudron-catalog-publish-caller.yml` and review `reference/release-artifact-provenance.md` before the first publication.

`packageUrl` controls the package-source link in Community Apps and should point to the package repository. It requires `minBoxVersion` 10.0.0. Keep `packagerUrl` pointed at the package maintainer; do not repurpose it as the repository link. Packages that need Cloudron 9.1 compatibility should omit `packageUrl`, while packages that require a repository link should raise the minimum explicitly. `author` and `contactEmail` are deprecated in the manifest reference but are still required by the current CLI version-catalog validator.

Use package-controlled, stable asset URLs where possible. The CLI copies the manifest into each catalog entry, freezing `iconUrl` and `mediaLinks` per published version; pin assets to `raw.githubusercontent.com/<owner>/<repo>/<full commit SHA>/<path>`, not a branch.
Keep the pinned commit reachable from the default branch: use a merge commit, not a squash merge, or re-pin to the merged `main` SHA before publishing. Squashing does not retain the original pinned commit in default-branch history; after the PR branch is deleted, that commit may eventually be garbage-collected.
Unauthenticated `raw.githubusercontent.com` URLs for catalogs, icons and media in private repositories return 404. Make the repository public or host these files elsewhere before URL checks and Community Apps import.
If an upstream asset is used temporarily, preserve a reviewed local copy and replace the remote reference before the upstream URL becomes unstable. Check every asset URL for an HTTPS 200 response and an image content type before publishing; check the catalog URL separately for valid JSON.

Keep a reproducible slide renderer (HTML template + headless-browser script) and original screenshots in the repository; record provenance, including the upstream commit and licence, in `DESIGN.md`. Upstream documentation screenshots under a permissive licence are an acceptable source when product screenshots require login. Review every slide for credentials, private host names and unverified claims before publishing.

## Registry Builder

| Command | Purpose |
|---------|---------|
| `cloudron builder login` | Authenticate with the Container registry app (registry URL, username, app password) |
| `cloudron builder build` | Build from the package directory and push a registry image |
| `cloudron builder reset` | Clear the remembered repository |

The current CLI no longer has `cloudron build`. Do not mechanically carry its
old flags or subcommands over to `cloudron builder`; inspect the installed CLI's
`cloudron builder --help` and `cloudron builder build --help` first.

`cloudron versions add` uses the last builder image and asks for confirmation on
a TTY. `--last-build` selects it without the prompt; `--image <registry-image>`
records a specific real image without a prompt. Never use either option to invent
an unbuilt image. Private repositories must be made public or configured in the
Cloudron server's private-registry settings before installation.

## Versions Commands

| Command | Purpose |
|---------|---------|
| `cloudron versions add --last-build` | Add current version (reads manifest + last builder image, no prompt) |
| `cloudron versions add --image <registry-image>` | Add current version with an explicit existing registry image |
| `cloudron versions list` | List all versions with date, image, and publish state |
| `cloudron versions update --version=1.0.0 --state=published` | Change publish state |
| `cloudron versions revoke` | Mark latest published version as revoked |

**Rules:** Do not change the manifest or image of a published version. Treat catalog entries as append-only release records. To ship changes: revoke only when necessary, bump the package version, rebuild, and add a new entry. Never copy a Docker tag or digest into the catalog by hand.

Typical release cycle:

```bash
# 1. Edit code, bump version in CloudronManifest.json
# 2. Build and push
cloudron builder build

# 3. Add to catalog as a test candidate
cloudron versions add --last-build --state testing

# 4. Host the catalog and test a clean install/upgrade via its public URL
cloudron versions list

# 5. Promote the exact tested entry
cloudron versions update --version=1.1.0 --state=published

# 6. Commit and push CloudronVersions.json to hosting
git add CloudronVersions.json && git commit -m "release 1.1.0" && git push
```

Before promotion, verify fresh install, upgrade from the previous published version, restart, backup/restore, health checks, and the public icon/media URLs. Image push, catalog promotion, catalog hosting, and Community Apps submission are publication actions and require explicit authorization.

### Catalog Updates Versus Source Rebuilds

`cloudron update --app <app>` run in a package checkout whose manifest has no
`dockerImage` uploads that source and builds a server-side `local/...` image. It
does not exercise the catalog, so it is not evidence for an upgrade from a
published version. Keep it labelled as development iteration in package docs.

To test a published upgrade, install the previous version with
`cloudron install --versions-url <url>`, then either update from the dashboard
or run `cloudron update --app <app>` in a scratch directory holding only the
catalog's `.versions["X.Y.Z"].manifest` (which carries the digest-pinned
`dockerImage`). Confirm `cloudron status --app <app>` reports that digest.

### Moving a source-built install to a catalog-linked install

Switch the existing app in place. It keeps its app ID, data, database, location
and mailbox (verified on Cloudron 10.1.5 with CLI 9.0.3):

```bash
cloudron --version   # needs 9.0+; otherwise prefix the commands below with npx -y cloudron@9
cloudron update --app <app> --versions-url <catalog-url> --force
cloudron status --app <app>   # Source: <catalog-url>; Docker image: the catalog digest
```

`--force` permits the source-type change. The update backs up first unless
`--no-backup` is passed, then replaces the `local/...` image with the catalog's
pinned image. Afterwards check health and sign-in, and that persistent secrets in
`/app/data` were reused, not regenerated. CLI 8.x has no `update --versions-url`,
and updating from a scratch manifest selects the pinned image without linking the
app for catalog updates. `npx` uses the same `~/.cloudron.json` login.

Avoid the reinstall route (back up, `cloudron install --versions-url` at a
temporary location, then `cloudron import`): CLI 8.2.6 and 9.0.3 send
`backupFormat`, which Cloudron 10 rejects with `400 format must be string`. Use
it only through the dashboard's import, or for a fresh start from a test app.

### Pre-Merge CLI Dry Run

Publisher tests that stub the CLI cannot catch changelog or `file://` parsing
errors; those then fail in the post-merge publish job. On pull requests, copy the
manifest, catalog, and every `file://` reference to a scratch directory, run the
pinned real CLI's `cloudron versions add --state testing --image
registry.invalid/dry-run@sha256:<64 zeros>` and `cloudron versions verify`, and
discard the result. Skip when the manifest version is already in the catalog.

### Managed Catalog Workflow

New `aidevops init` Cloudron projects receive both the legacy tag-release caller
and the pinned catalog caller. Existing packages opt in by copying
`templates/workflows/cloudron-catalog-publish-caller.yml` to
`.github/workflows/cloudron-catalog-publish.yml`, or running
`cloudron-package-helper.sh scaffold catalog`. Existing workflows are never
overwritten by default. To replace an inline publisher, run
`cloudron-package-helper.sh scaffold catalog --migrate [package-directory]`
(requires Ruby with its standard YAML library). Migration uses the managed
template's immutable pin, which includes GH#35649 push-race recovery and GH#35650
no-push PR builds. It moves unconditional package shell-script checks into
`package_checks` and preserves literal image and paired CLI inputs. Unmapped
jobs, steps or configuration are listed and block migration without modifying
the original. In particular, integrate Nostr Relay's `runtime-smoke` explicitly;
do not remove it to make migration pass. Already-reusable callers require manual
pin/input review rather than being reset. Review every generated diff, including
the standard publisher steps replaced by the reusable workflow.

Roll out one migration PR per package after the helper lands. Keep
`CloudronManifest.json` version unchanged, confirm it is already published and
its existing tag/release are complete, and verify the PR preflight's no-push
image build before merge. Do not modify catalog entries, tags or releases as
part of migration. Only after reviewing the existing publication prerequisites,
set the repository variable `CLOUDRON_PUBLICATION_ENABLED=true`; this is required
for **both publication and upstream monitor reconcile**, including packages whose
old inline workflow published without the variable. Enabling it with an
unpublished manifest version or incomplete release can publish/reconcile that
version, so an unchanged manifest alone is not proof of a no-publication rollout.

The caller pins the reusable workflow by immutable commit SHA;
`aidevops_ref` must match that pin and constrains attestation signer verification.
Keep the original pin available when reconciling catalogs signed by that revision;
updating a caller does not authorize an older signer automatically.

The caller grants the permission ceiling (`contents`, `packages`, `attestations`
write and OIDC); each reusable job narrows its permissions. Only preflight runs
on PRs: static manifest/Dockerfile checks, ShellCheck, optional `package_checks`
(set this input to the package's static checks and pinned-upstream patch check),
the real CLI catalog dry run above, and a no-push `linux/amd64` image build at
the validated SHA. Preflight proves the image builds before merge: a failing
Dockerfile fails that same check, even when publication is disabled or the version
already exists in the catalog. Its 45-minute job timeout bounds the build, and its
read-only token has no GHCR write permission. No registry login or publication
credential is exposed to those commands. The PR and main builds share the platform
setting, image tag, metadata output and build context; only main may push.
The CLI version and npm sha512 integrity are pinned together;
the registry metadata and installed lockfile integrity must both match, and
lifecycle scripts are disabled. Override both CLI inputs together after review.
This pins the CLI package, not its entire transitive npm dependency graph; it is
not a reproducible dependency closure. The dry run also exercises state promotion
with an explicit image, which a stateless runner needs even for `versions update`.

Publication is disabled until the repository **variable**
`CLOUDRON_PUBLICATION_ENABLED` equals `true`. Even then, only `push` or
`workflow_dispatch` runs on `refs/heads/main` may publish (including no
`pull_request_target` exception). No personal token is needed under the
protection baseline below: the per-run job token (scoped to this repository,
expiring with the job) pushes to GHCR and, in the final publish step only,
pushes the catalog commit and tag. That is narrower than any PAT and needs no
rotation. The caller still forwards the optional repository **secret**
`CLOUDRON_RELEASE_PAT`; set it only when rules on `main` block a direct
job-token push (required pull requests, status checks or deployments, or
restricted updates). The approval, scaffold and monitor helpers check
`gh api repos/<owner/repo>/rules/branches/main` and require the secret only in
that case; classic branch protection is not inspected. This workflow never
changes or bypasses branch policy. Review protection, Actions permissions and
package checks before enabling the variable. Do not test publication against a
real catalog.

**When a publication PAT is needed:** reuse one purpose-scoped fine-grained
`CLOUDRON_RELEASE_PAT` per owner, separate from `SYNC_PAT`. Select **Only select
repositories** and include every package repository that needs it (for example,
the owner's `cloudron-*-app` repositories). Grant repository **Contents:
read/write** and the automatically included **Metadata: read** only; no workflow
or user permissions. Store the value once in gopass, not once per repository.

**Add a new package repo:** open GitHub **Settings → Developer settings →
Fine-grained tokens → CLOUDRON_RELEASE_PAT → Edit** and add the repository to
the existing token's access list if absent. Editing access leaves the value
unchanged. Set the repository's Actions secret from gopass without displaying it:

```bash
aidevops secret CLOUDRON_RELEASE_PAT -- sh -c 'printf %s "$CLOUDRON_RELEASE_PAT" | gh secret set CLOUDRON_RELEASE_PAT --repo OWNER/REPO'
```

GitHub user accounts have no account-level Actions secrets: set the same value
in each repository that needs it. **First time / value lost:** create the token
only if none exists; if its value is lost, **Regenerate** the existing token
(permissions and repository list are retained). Run
`aidevops secret set CLOUDRON_RELEASE_PAT` in a terminal to save the value in
gopass. Then set the secret from gopass in **every repository listed on the
token**: regeneration revokes the old value and invalidates every existing copy.
Never paste values into chat or logs.

**Verify distribution without reading values:** run
`gh secret list --repo OWNER/REPO --app actions` for each repository updated and
confirm `CLOUDRON_RELEASE_PAT` is listed. Presence alone does not prove the
token's repository access, permissions or branch-policy bypass; review those
separately. Do not trigger a real publication to test token distribution.

**Repository protection:** before enabling publication, a maintainer should
deliberately apply these two repository rulesets with `enforcement: active` and
no bypass actors:

| Ruleset name | Target and ref pattern | Rule types |
|--------------|------------------------|------------|
| Protect default branch | Branch: `~DEFAULT_BRANCH` | `non_fast_forward`, `deletion` |
| Protect package release tags | Tag: `refs/tags/v*` | `update`, `deletion` |

In GitHub, open the package repository's **Settings → Rules → Rulesets** and
review existing rulesets first; edit a same-named ruleset rather than creating a
duplicate. Create a branch ruleset targeting the default branch, enable **Block
force pushes** and **Restrict deletions**, and set enforcement to **Active** with
an empty bypass list. Create a tag ruleset targeting `v*` (API ref pattern
`refs/tags/v*`), enable **Restrict updates** and **Restrict deletions**, and use
the same enforcement and bypass settings. Leave **Restrict creations** disabled:
the publishing workflow must be able to create new version tags. Review any
other applicable rulesets too; these settings do not override stricter rules.

This baseline permits the catalog workflow's atomic fast-forward push to `main`
and creation of a new `v*` tag, but prevents rewriting or deleting an existing
release tag. Metrics and Star History also only fast-forward the default branch;
the metrics helper's force-with-lease push targets its own PR branch, outside
`~DEFAULT_BRANCH`. No protection bypass is needed for these operations.

Requiring pull requests and required checks is a separate, optional policy, not
part of this baseline. It blocks these workflows' direct pushes to `main` unless
the owner is an authorized bypass actor and the pushes authenticate with owner
PATs (`CLOUDRON_RELEASE_PAT` for catalog publication, `SYNC_PAT` for sync
workflows). If you adopt it, one fine-grained PAT covering all affected package
repositories per owner and purpose is enough: Contents write for publication;
see `reference/sync-pat-platforms.md` for sync permissions. Keep release and sync
tokens separate; extend each token's selected repository list rather than
creating a token per repository.
This bypass path is
**untested with fine-grained PATs**; do not
recommend or enable it without separately verifying the token permissions,
bypass configuration and affected workflows.

The build is `linux/amd64`, checked out at the exact validated SHA. An existing
version in the catalog is never rebuilt or retagged: the reconciliation path
only verifies the existing tag/catalog provenance and repairs a missing GitHub
release. A pushed image without a catalog entry is reused only when its
attestation verifies for the same source SHA and reusable workflow. If the first
GHCR push creates a private package, make that package public and rerun the same
source revision. Anonymous image inspection must succeed before catalog
publication. A tag with absent or mismatched provenance fails closed; investigate
it rather than deleting or overwriting it automatically.

The generated catalog is attested and its exact bundle verified before a
catalog-only commit and tag are pushed atomically. If `main` advances, publication
fetches it and retries once after rebasing only the catalog commit. Every
intervening change must be allowlisted documentation or metrics/Star History
assets (`README.md`, `docs/`, `metrics/`, `.github/metrics/`,
`.github/star-history/`, or root `star-history.svg`/`star-history-dark.svg`).
Package inputs, catalog changes, rewritten ancestry, conflicts, or a second race
fail closed. Catalog bytes remain unchanged, and the commit records the original
validated SHA for both catalog and image attestation verification. Caller concurrency
serializes main runs and never cancels an in-flight publication. Existing
catalogs without this workflow's attestations require an owner-reviewed
provenance adoption before release reconciliation; it never fabricates evidence.

The daily `cloudron-package-monitor-helper.sh upstream` check reports a remote
main manifest version missing from the catalog when publication is enabled and
no catalog run is active. With `--apply` and ADMIN/MAINTAIN authority it dispatches
the existing main workflow once per version, with a local persistent receipt
under `~/.aidevops/cache/cloudron-catalog-reconcile/`. Failed dispatches may retry;
a successfully dispatched but failed workflow requires investigation before
removing that version's receipt. This resumes already-authorized publication;
it does not enable publication, alter caller pins, or bypass workflow gates.

The catalog workflow creates the GitHub release itself, from the tagged
catalog's embedded version changelog, after checking tag ancestry, public image
access and catalog provenance. **Do not depend on the legacy tag caller for
catalog-published versions:** the catalog commit's skip-CI marker also suppresses
its tag-push workflow. The legacy caller remains for packages without catalog
automation. Only the generated catalog commit may contain the literal skip-CI
marker; describe it in prose elsewhere, because GitHub matches it anywhere in a
head commit message. No image/catalog/deployment publication is performed by the
legacy caller.

## Keyless Publication Provenance

For aidevops-packaged community apps, GitHub Actions OIDC/Sigstore provenance is
the default release design. Pin the package image by digest; attest both that OCI
digest and the exact generated catalog bytes; verify each emitted bundle against
the package repository, exact catalog workflow, and protected source ref before
committing or promoting the catalog. Add a no-version-bump path that attests the
existing catalog when this control is first adopted.

Cloudron does not currently verify external Sigstore attestations when importing
`CloudronVersions.json` or applying automatic updates. Describe the result as
tamper evidence and publisher provenance, not client-enforced signing. A checksum
beside the catalog does not close this gap because the same compromised host can
replace both. Full workflow and verification pattern:
`reference/release-artifact-provenance.md`.

## Distribution

- **Dashboard**: add `CloudronVersions.json` URL under Community apps in dashboard settings — updates appear automatically
- **CLI**: `cloudron install --versions-url <url>`
- **Community listing**: sign in to [Cloudron Community Apps](https://ca.cloudron.io), open the publisher's apps, add the same versions URL, and confirm the imported title, icon, screenshot, changelog, and install URL. The listing is optional and does not host the catalog. Both the listing and forum announcement are publication actions that require explicit authorization. Then announce it in the forum's [Community Apps category](https://forum.cloudron.io/category/220/community-apps).

## Community Packages (9.1+)

Community packages can be non-free (paid). Publishers keep Docker images private; end users set up a [private Docker registry](https://docs.cloudron.io/docker#private-registry) for access.
