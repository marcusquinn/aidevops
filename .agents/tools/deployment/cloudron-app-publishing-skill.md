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

## Quick Reference

- **Docs**: [docs.cloudron.io/packaging/publishing](https://docs.cloudron.io/packaging/publishing)
- **Upstream skill**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-app-publishing`)
- **Prerequisite**: App must be built with `cloudron build` (local or build service) — on-server builds cannot be published
- **Key file**: `CloudronVersions.json` — version catalog hosted at a public URL
- **Forum**: [App Packaging & Development](https://forum.cloudron.io/category/96/app-packaging-development)

## Workflow

```bash
cloudron versions init  # creates CloudronVersions.json + DESCRIPTION.md, CHANGELOG, POSTINSTALL.md (edit all placeholders)
cloudron build          # build and push image (first run prompts for Docker repository, e.g. registry/username/myapp)
cloudron versions add   # add version to catalog
# host CloudronVersions.json at a public URL
```

## Required Manifest Fields

`id`, `title`, `author`, `tagline`, `version`, `website`, `contactEmail`, `iconUrl`, `packagerName`, `packagerUrl`, `tags` (array), `mediaLinks` (array), `description` (`file://DESCRIPTION.md`), `changelog` (`file://CHANGELOG`), `postInstallMessage` (`file://POSTINSTALL.md`), `minBoxVersion` (e.g. `9.1.0`).

## Build Commands

| Command | Purpose |
|---------|---------|
| `cloudron build` | Build and push image (local or remote) |
| `cloudron build --no-cache` | Rebuild without Docker cache |
| `cloudron build --no-push` | Build but skip push |
| `cloudron build -f Dockerfile.cloudron` | Use specific Dockerfile |
| `cloudron build --build-arg KEY=VALUE` | Pass Docker build args |
| `cloudron build reset` | Clear saved repository, image, and build info |
| `cloudron build info` | Show current build config |
| `cloudron build login` / `logout` | Authenticate with remote build service |
| `cloudron build logs --id <id>` | Stream logs for a remote build |
| `cloudron build push --id <id>` | Push a remote build to a registry |
| `cloudron build status --id <id>` | Check status of a remote build |

## Versions Commands

| Command | Purpose |
|---------|---------|
| `cloudron versions add` | Add current version (reads manifest + last built image) |
| `cloudron versions list` | List all versions with date, image, and publish state |
| `cloudron versions update --version 1.0.0 --state published` | Change publish state |
| `cloudron versions revoke` | Mark latest published version as revoked |

**Rules:** Do not change the manifest or image of a published version. To ship changes: revoke, bump version in `CloudronManifest.json`, rebuild, `cloudron versions add`.

## Distribution

- **Dashboard**: add `CloudronVersions.json` URL under Community apps in dashboard settings — updates appear automatically
- **CLI**: `cloudron install --versions-url <url>`

## Community Packages (9.1+)

Community packages can be non-free (paid). Publishers keep Docker images private; end users set up a [private Docker registry](https://docs.cloudron.io/docker#private-registry) for access.
