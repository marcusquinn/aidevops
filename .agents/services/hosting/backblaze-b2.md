---
description: Guarded Backblaze B2 cloud storage operations through rclone and the official B2 MCP
mode: subagent
tools:
  read: true
  bash: true
  backblaze-b2_*: true
mcp:
  - backblaze-b2
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Backblaze B2 Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Deterministic storage operations**: `object-storage-helper.sh` with an explicit `backblaze-b2` account alias.
- **MCP**: `@backblaze-labs/b2-mcp@0.2.1`, disabled globally and activated only by this agent.
- **Authentication**: Store only `B2_APPLICATION_KEY_ID` and `B2_APPLICATION_KEY` with `aidevops secret`. Never request, store, or pass B2 master keys.
- **Activation**: Connect `backblaze-b2`, inspect the actual MCP tool schemas, then disconnect when finished.
- **Large transfers and backup verification**: Prefer the helper/rclone and presigned byte paths over MCP payload transfers.

<!-- AI-CONTEXT-END -->

## Safe operating boundary

Backblaze B2 cloud storage is distinct from the Backblaze desktop backup client.
Use this agent only for B2 buckets and B2/S3-compatible storage operations.

Read-only discovery may use the connected MCP after confirming the account alias and
target. The baseline blocks destructive calls, key management, partner/group
administration, durable-secret output, inline secrets, and arbitrary local-file
access. Do not infer tool names or parameters: inspect the connected schema first.

For backup verification, use the bounded helper rather than a broad MCP listing:

```bash
object-storage-helper.sh readiness <account-alias>
object-storage-helper.sh verify-backups <account-alias> <allowed-bucket>
```

The helper keeps rclone credentials outside its config, constrains account aliases
and bucket allowlists, and leaves transfers in dry-run mode. Before any future
mutation workflow, require an exact target, an explicit approved operation, and
read-back verification. Disconnect the MCP after a completed B2 task or failure.
