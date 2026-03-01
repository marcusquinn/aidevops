---
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

# Cloudron App Publishing

Distribute Cloudron apps independently using a `CloudronVersions.json` version catalog. Users add the file's URL in their dashboard or install via `cloudron install --versions-url <url>`.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Publish and distribute Cloudron app packages outside the official App Store
- **Docs**: [docs.cloudron.io/packaging/publishing](https://docs.cloudron.io/packaging/publishing)
- **Upstream skill**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-app-publishing`)
- **Prerequisite**: App must be built with `cloudron build` (local or build service) -- on-server builds cannot be published
- **Key file**: `CloudronVersions.json` -- version catalog hosted at a public URL
- **Install method**: Dashboard "Community apps" or `cloudron install --versions-url <url>`

<!-- AI-CONTEXT-END -->

## Prerequisites

The app must be built and pushed to a registry with `cloudron build`. On-server builds (`cloudron install` without `--image`) do not produce registry-hosted images and cannot be published.

## Workflow

```bash
cloudron versions init       # create CloudronVersions.json, scaffold manifest
cloudron build               # build and push image
cloudron versions add        # add version to catalog
# host CloudronVersions.json at a public URL
```

## Initialize

```bash
cloudron versions init
```

Creates `CloudronVersions.json` in the package directory. Also adds missing publishing fields to `CloudronManifest.json` with placeholder values and creates stub files:

- `DESCRIPTION.md` -- detailed app description
- `CHANGELOG` -- version changelog
- `POSTINSTALL.md` -- post-install message shown to users

Edit all placeholders and stubs before adding a version.

### Required Manifest Fields for Publishing

Beyond what `cloudron init` provides, publishing requires:

| Field | Example |
|-------|---------|
| `id` | `com.example.myapp` |
| `title` | `My App` |
| `author` | `Jane Developer <jane@example.com>` |
| `tagline` | `A short one-line description` |
| `version` | `1.0.0` |
| `website` | `https://example.com/myapp` |
| `contactEmail` | `support@example.com` |
| `iconUrl` | `https://example.com/icon.png` |
| `packagerName` | `Jane Developer` |
| `packagerUrl` | `https://example.com` |
| `tags` | `["productivity", "collaboration"]` |
| `mediaLinks` | `["https://example.com/screenshot.png"]` |
| `description` | `file://DESCRIPTION.md` |
| `changelog` | `file://CHANGELOG` |
| `postInstallMessage` | `file://POSTINSTALL.md` |
| `minBoxVersion` | `9.1.0` |

`cloudron versions init` scaffolds all of these with defaults.

## Build Commands

### cloudron build

Builds the Docker image. Behavior depends on whether a build service is configured:

```bash
cloudron build                          # build (local or remote)
cloudron build --no-cache               # rebuild without Docker cache
cloudron build --no-push                # build but skip push
cloudron build -f Dockerfile.cloudron   # use specific Dockerfile
cloudron build --build-arg KEY=VALUE    # pass Docker build args
```

On first run, prompts for the Docker repository (e.g. `registry/username/myapp`). Remembers it for subsequent runs.

### Other Build Subcommands

| Command | Purpose |
|---------|---------|
| `cloudron build reset` | Clear saved repository, image, and build info |
| `cloudron build info` | Show current build config (image, repository, git commit) |
| `cloudron build login` | Authenticate with a remote build service |
| `cloudron build logout` | Log out from the build service |
| `cloudron build logs --id <id>` | Stream logs for a remote build |
| `cloudron build push --id <id>` | Push a remote build to a registry |
| `cloudron build status --id <id>` | Check status of a remote build |

## Versions Commands

### cloudron versions add

Adds the current version to `CloudronVersions.json`. Reads the version from `CloudronManifest.json` and the last built Docker image.

```bash
cloudron versions add
```

### cloudron versions list

```bash
cloudron versions list
```

Shows all versions with their creation date, image, and publish state.

### cloudron versions update

Updates an existing version entry. Primarily used to change the publish state.

```bash
cloudron versions update --version 1.0.0 --state published
```

Avoid changing the manifest or image of a published version -- users may have already installed it. To ship changes, revoke the existing version and add a new one.

### cloudron versions revoke

Marks the latest published version as revoked. Users who have not yet updated will not receive it.

```bash
cloudron versions revoke
```

To ship a fix: bump the version in `CloudronManifest.json`, rebuild, run `cloudron versions add`.

## Distribution

Host `CloudronVersions.json` at any publicly accessible URL (static file host, git repo, web server).

Users install in two ways:

- **Dashboard** -- Add the URL under Community apps in the dashboard settings. Updates appear automatically.
- **CLI** -- `cloudron install --versions-url <url>`

## Typical Release Cycle

```bash
# 1. Edit code, bump version in CloudronManifest.json
# 2. Build and push
cloudron build

# 3. Add to catalog
cloudron versions add

# 4. Commit and push CloudronVersions.json to hosting
git add CloudronVersions.json && git commit -m "release 1.1.0" && git push
```

## Community Packages (9.1+)

Community packages can be non-free (paid). The package publisher can keep Docker images private, and the end user sets up a [private Docker registry](https://docs.cloudron.io/docker#private-registry) to access the package. Automation of purchase/discovery is outside Cloudron's scope.

## Forum

Post about new packages in the [App Packaging & Development](https://forum.cloudron.io/category/96/app-packaging-development) category.
