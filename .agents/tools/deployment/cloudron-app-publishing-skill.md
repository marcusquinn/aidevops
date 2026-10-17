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
- A local square 256×256 PNG icon (`icon` normally points to it) and at least one privacy-reviewed product screenshot or hero. `mediaLinks` must use public HTTPS URLs; Cloudron recommends 3:1 images such as 1200×400.
- A Cloudron-format changelog file when using `file://`: each release heading must be exactly `[X.Y.Z]`, because `cloudron versions add` does not parse Keep a Changelog headings such as `## [X.Y.Z]`.
- A short publishing runbook that records the canonical catalog URL, registry/repository ownership, asset provenance, test install, rollback, and Community Apps listing steps without storing credentials.
- A managed GitHub Actions release workflow that creates and verifies keyless provenance for the immutable image digest and exact generated `CloudronVersions.json`; use `reference/release-artifact-provenance.md` before the first publication.

`packageUrl` controls the package-source link in Community Apps and should point to the package repository. It requires `minBoxVersion` 10.0.0. Keep `packagerUrl` pointed at the package maintainer; do not repurpose it as the repository link. Packages that need Cloudron 9.1 compatibility should omit `packageUrl`, while packages that require a repository link should raise the minimum explicitly. `author` and `contactEmail` are deprecated in the manifest reference but are still required by the current CLI version-catalog validator.

Use package-controlled, stable asset URLs where possible. If an upstream asset is used temporarily, preserve a reviewed local copy and replace the remote reference before the upstream URL becomes unstable. Check every URL for an HTTPS 200 response and an image content type before publishing.

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

### Pre-Merge CLI Dry Run

Publisher tests that stub the CLI cannot catch changelog or `file://` parsing
errors; those then fail in the post-merge publish job. On pull requests, copy the
manifest, catalog, and every `file://` reference to a scratch directory, run the
pinned real CLI's `cloudron versions add --state testing --image
registry.invalid/dry-run@sha256:<64 zeros>` and `cloudron versions verify`, and
discard the result. Skip when the manifest version is already in the catalog.

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
