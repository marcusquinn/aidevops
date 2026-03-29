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

## Workflow

```bash
cloudron versions init       # create CloudronVersions.json, scaffold manifest + stub files
cloudron build               # build and push image
cloudron versions add        # add version to catalog
# host CloudronVersions.json at a public URL
```

`cloudron versions init` also creates: `DESCRIPTION.md`, `CHANGELOG`, `POSTINSTALL.md`. Edit all placeholders and stubs before adding a version.

## Required Manifest Fields

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

## Build Commands

```bash
cloudron build                          # build (local or remote)
cloudron build --no-cache               # rebuild without Docker cache
cloudron build --no-push                # build but skip push
cloudron build -f Dockerfile.cloudron   # use specific Dockerfile
cloudron build --build-arg KEY=VALUE    # pass Docker build args
```

On first run, prompts for the Docker repository (e.g. `registry/username/myapp`). Remembers it for subsequent runs.

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

| Command | Purpose |
|---------|---------|
| `cloudron versions add` | Add current version (reads from manifest + last built image) |
| `cloudron versions list` | List all versions with date, image, and publish state |
| `cloudron versions update --version 1.0.0 --state published` | Change publish state of a version |
| `cloudron versions revoke` | Mark latest published version as revoked |

**Rules:**
- Do not change the manifest or image of a published version -- users may have already installed it.
- To ship changes: revoke, bump version in `CloudronManifest.json`, rebuild, `cloudron versions add`.

## Distribution

Host `CloudronVersions.json` at any publicly accessible URL (static file host, git repo, web server).

- **Dashboard** -- Add URL under Community apps in dashboard settings. Updates appear automatically.
- **CLI** -- `cloudron install --versions-url <url>`

## Community Packages (9.1+)

Community packages can be non-free (paid). The package publisher can keep Docker images private, and the end user sets up a [private Docker registry](https://docs.cloudron.io/docker#private-registry) to access the package. Automation of purchase/discovery is outside Cloudron's scope.

## Forum

Post about new packages in the [App Packaging & Development](https://forum.cloudron.io/category/96/app-packaging-development) category.
