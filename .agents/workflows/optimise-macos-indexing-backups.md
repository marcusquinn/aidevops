---
description: Audit and safely optimise macOS indexing and backup exclusions
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh macos scan $ARGUMENTS
```

## Safety contract

- Dry-run is the default.
- Do not exclude the whole home directory, project source trees, `Documents`, `Desktop`, `Downloads`, `.ssh`, `.gnupg`, or broad app support directories.
- Redact or avoid backup identity, login, token, and account fields in all output.
- Config-file mutation requires `--apply`, a backup copy, and XML/config validation.

## macOS coverage

- Spotlight: check `mdutil` status and create `.metadata_never_index` only in writable generated/cache directories.
- Time Machine: recommend `tmutil addexclusion`; verify with `tmutil isexcluded` when permissions allow.
- Backblaze: detect editable XML locations, recommend generic `bzexcluderules_editable.xml` rules, and avoid printing sensitive fields.
- High-churn paths: user caches, package caches, simulator caches, aidevops runtime cache/log/lock directories, and generated project directories such as `<repo-root>/**/node_modules/`, `<repo-root>/**/.turbo/`, `<repo-root>/**/dist/`, and `<repo-root>/**/coverage/`.

## Verification

Run:

```bash
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh macos scan --dry-run --json
~/.aidevops/agents/scripts/optimise-indexing-backups-helper.sh macos status
```
