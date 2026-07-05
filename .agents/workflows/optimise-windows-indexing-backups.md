---
description: Audit native Windows indexing and backup exclusions safely
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh windows scan $ARGUMENTS
```

## Support posture

- Native Windows remains outside full aidevops platform support.
- This workflow is a limited experimental local-ops command for Windows Search, File History/Windows Backup, OneDrive, and backup-client exclusion recommendations.
- WSL2 users should run `/optimise-linux-indexing-backups`; do not duplicate WSL2 coverage here.

## Safety contract

- Dry-run is the default and requires no administrator privileges.
- `--apply` writes a user-owned recommendation file only; it does not mutate Windows Search, File History, Windows Backup, OneDrive, Defender, or third-party backup-client settings.
- Never exclude the profile root, Desktop, Documents, Downloads, source trees, credential stores, `.ssh`, `.gnupg`, or broad application data directories.
- Use placeholders such as `<repo-root>`, `<user>`, and `<drive>` in shared output, tests, and docs.
- Avoid Windows Defender exclusion automation unless a future task proves a clear security-safe need.

## Native Windows coverage

- Windows Search: recommend indexing exclusions for reproducible generated paths; avoid broad profile exclusions.
- File History / Windows Backup: recommend reviewable exclusions where the tool exposes safe configuration, but do not rewrite unknown jobs.
- OneDrive Known Folder Move and sync clients: recommend selective sync/exclusion review instead of mutating account-specific config.
- Third-party tools: detect Backblaze, Dropbox, Google Drive, and rclone when possible without exposing identities.
- High-churn paths: `%LOCALAPPDATA%\Temp\`, package-manager caches, aidevops runtime cache/log/lock directories, and generated project patterns such as `<repo-root>\**\node_modules\`, `<repo-root>\**\.next\`, `<repo-root>\**\.turbo\`, `<repo-root>\**\dist\`, `<repo-root>\**\build\`, `<repo-root>\**\.venv\`, and `<repo-root>\**\__pycache__\`.

## Verification

Run:

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh windows scan --dry-run --json
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh windows status
```
