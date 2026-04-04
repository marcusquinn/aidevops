<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Manifest Reference — Metadata

## Metadata (for App Store / CloudronVersions.json)

| Field | Type | Description |
|-------|------|-------------|
| `id` | reverse domain string | Unique app ID (e.g. `com.example.myapp`) |
| `title` | string | App name |
| `author` | string | Developer name and email |
| `tagline` | string | One-line description |
| `description` | markdown string | Detailed description. Supports `file://DESCRIPTION.md` |
| `changelog` | markdown string | Changes in this version. Supports `file://CHANGELOG` |
| `website` | URL | App website |
| `contactEmail` | email | Bug report / support email |
| `icon` | local file ref | Square 256x256 icon (e.g. `file://icon.png`) |
| `iconUrl` | URL | Remote icon URL |
| `tags` | string array | Filterable tags: `blog`, `chat`, `git`, `email`, `sync`, `gallery`, `notes`, `project`, `hosting`, `wiki` |
| `mediaLinks` | URL array | Screenshot URLs (3:1 aspect ratio, HTTPS) |
| `packagerName` | string | Name of package maintainer |
| `packagerUrl` | URL | Package maintainer URL |
| `documentationUrl` | URL | Link to app docs |
| `forumUrl` | URL | Link to support forum |
| `upstreamVersion` | string | Upstream app version (display only) |
