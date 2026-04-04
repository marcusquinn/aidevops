<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Migration

## Import Existing Resources

```bash
pulumi import cloudflare:index/workerScript:WorkerScript my-worker <account_id>/<worker_name>
pulumi import cloudflare:index/workersKvNamespace:WorkersKvNamespace my-kv <namespace_id>
pulumi import cloudflare:index/r2Bucket:R2Bucket my-bucket <account_id>/<bucket_name>
```

## From Terraform or Wrangler

Use `pulumi import` and rewrite configs in Pulumi DSL. For `wrangler.toml`: create matching Pulumi resources, import, verify with `pulumi preview`, then switch deployments.
