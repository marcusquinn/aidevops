---
description: macOS indexing and backup optimisation guidance for Spotlight, Time Machine, and Backblaze
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# macOS Indexing and Backup Optimisation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Reduce local CPU, disk I/O, and backup churn from reproducible caches and generated files.
- **Command**: `/optimise-macos-indexing-backups`.
- **Helper**: `scripts/optimise-indexing-backups-helper.sh macos scan`.
- **Default**: dry-run recommendations only.

<!-- AI-CONTEXT-END -->

## Safe exclusions

Prefer generated/cache directories: `~/Library/Caches/`, `~/Library/Logs/`, `~/.cache/`, package-manager caches, simulator caches, aidevops cache/log/lock directories, and generated project paths like `<repo-root>/**/node_modules/`, `<repo-root>/**/.next/`, `<repo-root>/**/.turbo/`, `<repo-root>/**/dist/`, `<repo-root>/**/build/`, and `<repo-root>/**/coverage/`.

Do not exclude the whole home directory, project source trees, `Documents`, `Desktop`, `Downloads`, `.ssh`, `.gnupg`, broad configuration directories, or entire application support trees.

## System notes

- Spotlight: use `.metadata_never_index` for writable generated directories; use `mdutil -s` and `mdutil -a -s` for status only.
- Time Machine: recommend `tmutil addexclusion` and verify with `tmutil isexcluded` when permissions allow.
- Backblaze: editable rules live in `/Library/Backblaze.bzpkg/bzdata/bzexcluderules_editable.xml`; GUI-visible directory exclusions are `bzdirfilter` entries in `/Library/Backblaze.bzpkg/bzdata/bzinfo.xml` and should be mirrored to `.sidecopy` when present. Back up XML files, validate XML, and never print account, login, token, or identity fields. `skipFirstCharThenStartsWith` omits the leading slash, for example `users/<user>/` or `volumes/<volume>/`.
