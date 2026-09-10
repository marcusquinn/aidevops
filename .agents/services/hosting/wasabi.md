---
description: Guarded Wasabi object-storage integration through rclone
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Wasabi Object Storage Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: S3-compatible object storage, operated through rclone.
- **Config**: `configs/object-storage-config.json` holds a named Wasabi rclone remote and bucket allowlist; never add credentials to the template.
- **Commands**: `object-storage-helper.sh [readiness|list-buckets|list-objects|object-info|verify-backups|audit-protection|copy|download] <account> [args]`
- **Endpoint**: use an official Wasabi service URL. The canonical `https://s3.<region>.wasabisys.com` form must match the configured region; documented primary and regional aliases map to their canonical regions.
- **MCP**: defer registration. The official beta advertises a broad 140-tool surface spanning storage, IAM, and account governance, but this integration has no verified package pin, license, transport contract, or focused global-denial/agent-isolation evidence.

<!-- AI-CONTEXT-END -->

## Read-only Operations

Use an explicit account alias and its bucket allowlist. The helper rejects missing aliases, arbitrary URLs, non-Wasabi hosts, mismatched regions, unknown buckets, and unbounded listings before rclone runs.

```bash
object-storage-helper.sh readiness example-wasabi
object-storage-helper.sh list-buckets example-wasabi
object-storage-helper.sh list-objects example-wasabi example-wasabi-backups --limit 100
object-storage-helper.sh verify-backups example-wasabi example-wasabi-backups --max-age-days 7
object-storage-helper.sh audit-protection example-wasabi example-wasabi-backups
```

`verify-backups` establishes object freshness only, never restore success. `audit-protection` is a bounded manual-review signal, not a mutation capability.

## Guarded Changes

Copy and download remain dry-run previews, including after their exact confirmation token. Do not use this integration to alter IAM users or policies, account/sub-account settings, lifecycle rules, replication, retention, Object Lock, bucket policies, versioning, or delete objects.

Any future mutation requires an exact target, proposed effect, explicit approval, post-change read-back, and no automatic retry after an ambiguous response. Object Lock and retention can be irreversible; serialize future protection changes by exact bucket/key/version. Read-only audits may run concurrently.

## Configuration

Copy the credential-free template to the ignored local config and configure the named rclone remote separately. The helper never modifies rclone configuration.

```bash
cp configs/object-storage-config.json.txt configs/object-storage-config.json
object-storage-helper.sh readiness example-wasabi
```
