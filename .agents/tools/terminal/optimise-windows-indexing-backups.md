---
description: Native Windows indexing and backup optimisation guidance for Windows Search, File History, OneDrive, and backup clients
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Native Windows Indexing and Backup Optimisation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Reduce Windows indexing and backup churn from reproducible caches and generated files.
- **Command**: `/optimise-windows-indexing-backups`.
- **Helper**: `scripts/optimise-indexing-backups-helper.sh windows scan`.
- **Support**: limited experimental command only; WSL2 uses `/optimise-linux-indexing-backups`.
- **Default**: dry-run recommendations only.

<!-- AI-CONTEXT-END -->

## Safe exclusions

Prefer user-owned generated/cache paths: `%LOCALAPPDATA%\Temp\`, package-manager caches, aidevops cache/log/lock directories, and generated project paths like `<repo-root>\**\node_modules\`, `<repo-root>\**\.next\`, `<repo-root>\**\.turbo\`, `<repo-root>\**\dist\`, `<repo-root>\**\build\`, `<repo-root>\**\.venv\`, and `<repo-root>\**\__pycache__\`.

Do not exclude the profile root, Desktop, Documents, Downloads, source trees, credential stores, `.ssh`, `.gnupg`, broad application data directories, or backup-provider account/config roots wholesale.

## System notes

- Windows Search: audit/recommend exclusion candidates only; do not disable indexing globally.
- File History / Windows Backup: recommend reviewable exclusions where discoverable; do not rewrite unknown jobs or require administrator privileges in scan mode.
- OneDrive Known Folder Move: recommend selective sync/exclusion review. Do not print account IDs, tenant names, local private basenames, or sync-root paths.
- Backblaze, Dropbox, Google Drive, and rclone: detect without exposing identities; prefer generated exclude/recommendation files over mutating app-specific config.
- Windows Defender: avoid exclusion automation unless a future security-reviewed change proves a narrow, safe need.

## Apply scope

`--apply` writes a reusable recommendation file under `~/.aidevops/configs/` and records state. It is intentionally idempotent and does not mutate Windows Search, File History, Windows Backup, OneDrive, Defender, or backup-client settings.
