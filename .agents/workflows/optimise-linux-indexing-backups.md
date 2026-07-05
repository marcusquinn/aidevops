---
description: Audit and safely optimise Linux indexing and backup exclusions
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh linux scan $ARGUMENTS
```

## Safety contract

- Dry-run is the default.
- Detect installed systems before recommending edits.
- Do not require sudo in default mode; print privileged follow-up steps instead.
- Prefer a generated exclude file under `~/.aidevops/configs/` over rewriting unknown backup jobs.

## Linux coverage

- Indexers: GNOME Tracker/Tracker3, KDE Baloo, Recoll, and locate/plocate/mlocate pruning.
- Backup tools: restic, borg, kopia, duplicity/deja-dup, rsnapshot, rclone, and Timeshift where installed.
- High-churn paths: `~/.cache/`, trash, package caches, cargo registries, container/build caches where detected, aidevops runtime caches, and generated project directories such as `<repo-root>/**/.venv/`, `<repo-root>/**/target/`, `<repo-root>/**/__pycache__/`, and `<repo-root>/**/.pytest_cache/`.

## Verification

Run:

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh linux scan --dry-run --json
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh linux status
```
