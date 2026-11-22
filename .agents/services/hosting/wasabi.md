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

Copy and download remain dry-run previews, including after their exact confirmation token. Do not use this integration to alter IAM users or policies, account/sub-account settings, lifecycle rules, replication, retention, Object Lock, bucket policies, versioning, or delete objects (except source retirement after verified migration; see Bucket Migration).

Any future mutation requires an exact target, proposed effect, explicit approval, post-change read-back, and no automatic retry after an ambiguous response. Object Lock and retention can be irreversible; serialize future protection changes by exact bucket/key/version. Read-only audits may run concurrently.

## Bucket Migration

Move buckets to another S3-compatible account (for example IDrive e2) with `object-storage-helper.sh migrate-plan|migrate-run|migrate-retire-source <src-account> <dst-account>`. Both buckets must be allowlisted on both accounts; rclone >= 1.70 is required (older releases hold whole listings in memory).

1. `migrate-plan` is read-only: region, versioning, objects, bytes and newest upload. Object Lock, public ACL and bucket policy are flagged for manual provider review; policies and ACLs are never copied.
2. `migrate-run --confirm migrate:<src>:<dst>` copies then verifies (`rclone check --one-way`), records `VERIFIED`/`COPY_FAIL`/`CHECK_FAIL` per bucket, and resumes by skipping verified buckets. `--lane large|small` selects memory-bounded tuning (large: transfers x upload-concurrency x chunk-size); `--remote-host <alias>` runs rclone over SSH using remotes already configured there.
3. `migrate-retire-source --bucket <b> --confirm retire:<src>:<dst>:<b>` is the **only** delete exception: it refuses unless status is `VERIFIED`, the token matches exactly, and a fresh check passes immediately before purge. One bucket per call. Prefer finishing a bucket over killing a run; interrupted multipart uploads are cleaned with `rclone backend cleanup` after each copy.

## Configuration

Copy the credential-free template to the ignored local config and configure the named rclone remote separately. The helper never modifies rclone configuration.

```bash
cp configs/object-storage-config.json.txt configs/object-storage-config.json
object-storage-helper.sh readiness example-wasabi
```
