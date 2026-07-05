---
description: Linux indexing and backup optimisation guidance for local indexers and backup tools
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Linux Indexing and Backup Optimisation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Reduce local indexing and backup churn from reproducible caches and generated files.
- **Command**: `/optimise-linux-indexing-backups`.
- **Helper**: `scripts/optimise-indexing-backups-helper.sh linux scan`.
- **Default**: dry-run recommendations only.

<!-- AI-CONTEXT-END -->

## Safe exclusions

Prefer user-owned generated/cache paths: `~/.cache/`, `~/.local/share/Trash/`, package-manager caches, cargo registries, aidevops cache/log/lock directories, and generated project paths like `<repo-root>/**/node_modules/`, `<repo-root>/**/.venv/`, `<repo-root>/**/venv/`, `<repo-root>/**/target/`, `<repo-root>/**/__pycache__/`, and `<repo-root>/**/.pytest_cache/`.

Do not exclude the whole home directory, source trees, documents, secrets, or broad configuration directories.

## System notes

- Indexers: detect Tracker/Tracker3, Baloo, Recoll, and locate/plocate/mlocate before recommending changes.
- Backup tools: detect restic, borg, kopia, duplicity/deja-dup, rsnapshot, rclone, and Timeshift. Prefer a generated exclude file under `~/.aidevops/configs/` and show how to reference it rather than rewriting unknown jobs.
- Privileged config such as `/etc/updatedb.conf` should be reported as a follow-up command for the operator, not silently edited.
