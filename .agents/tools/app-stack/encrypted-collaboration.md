---
description: Encrypted and local-first collaboration boundaries for app stacks
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Encrypted Collaboration

Add encryption and collaboration deliberately. Start by identifying which data must be local-only, workspace-shared, server-visible, or end-to-end encrypted.

## Data classes

| Class | Storage pattern |
|-------|-----------------|
| Public/static | Static files or public database rows |
| Workspace shared | Postgres rows with RLS and audit |
| Local private | Device store, PGlite/SQLite, or OS keychain-backed files |
| Secret material | aidevops secret storage, OS keychain, or encrypted config; never renderer rows |
| End-to-end encrypted | Client-side encrypted payloads; server stores ciphertext and metadata only |

## Collaboration choices

- For normal business apps, start with server-authoritative Postgres + RLS + audit.
- Add local cache/offline when workflows require disconnected reads or fast desktop startup.
- Add conflict handling only for records that can be edited concurrently offline.
- Add E2EE only for fields/files where server operators must not read content.

## AI context rules

- AI agents receive decrypted content only when the workspace/user grants that scope.
- Store AI memory references with workspace and sensitivity metadata.
- Redact secrets and private keys before prompts, logs, comments, and public PRs.
- Audit AI tool calls against workspace, actor, input class, and output destination.

## Verification

- Classify each data type before implementation.
- Prove the server cannot read E2EE fields if that is a requirement.
- Prove renderer code cannot access secret material directly.
- Test sync/conflict behaviour with two clients before calling collaboration ready.
