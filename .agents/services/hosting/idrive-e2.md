---
description: Guarded IDrive e2 object-storage integration
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

# IDrive e2 Object Storage Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: S3-compatible object storage, operated through rclone
- **Config**: `configs/object-storage-config.json` with a named IDrive e2 rclone remote; never add credentials to the template
- **Commands**: `object-storage-helper.sh [readiness|list-buckets|list-objects|object-info|verify-backups|audit-protection|copy|download] <account> [args]`
- **Endpoint**: configure only `https://s3.<region>.idrivee2.com` and make `<region>` exactly match the config `region`
- **Cloudron boundary**: Cloudron creates backups; this helper audits remote presence and freshness only. A listing is not restore evidence.
- **MCP**: do not register the current IDrive MCP. Reconsider only with official provenance, a usable license, pinned release, compatible transport/lifecycle, and focused activation tests.

<!-- AI-CONTEXT-END -->

## Read-only Operations

Use the explicit account alias and bucket allowlist from the local config. The helper rejects missing aliases, arbitrary URLs, non-IDrive hosts, mismatched regions, unknown buckets, and unbounded listings before invoking rclone.

```bash
object-storage-helper.sh readiness example-idrive-e2
object-storage-helper.sh list-buckets example-idrive-e2
object-storage-helper.sh list-objects example-idrive-e2 example-idrive-backups --limit 100
object-storage-helper.sh verify-backups example-idrive-e2 example-idrive-backups --max-age-days 7
object-storage-helper.sh audit-protection example-idrive-e2 example-idrive-backups
```

`verify-backups` reports object freshness, not a successful Cloudron restore. Treat presigned URLs as bearer capabilities; this integration neither creates nor returns them.

## Guarded Changes

Copy and download remain preview-only, even with their confirmation token. Do not use this integration to change lifecycle rules, retention, legal holds, Object Lock, bucket policies, versioning, or delete objects. Those operations require a future provider adapter with an explicit exact target (bucket/key/version), proposed effect, confirmation, post-change read-back, and no automatic retry after an ambiguous response.

Object Lock at bucket creation and compliance retention can be irreversible. Read-only audits can run concurrently; any future protection-changing operation must serialize by exact bucket/key/version target.

## Configuration

Copy the template to the ignored local config and configure the named remote through rclone separately. Keep endpoints and regions explicit; existing rclone remotes are not modified by this helper.

```bash
cp configs/object-storage-config.json.txt configs/object-storage-config.json
object-storage-helper.sh readiness example-idrive-e2
```
