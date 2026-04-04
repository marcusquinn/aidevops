<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Pulumi Provider

Programmatic management of Cloudflare resources via `@pulumi/cloudflare` v6.x: Workers, Pages, D1, KV, R2, DNS, Queues, etc.

**Packages:** TypeScript/JS: `@pulumi/cloudflare` | Python: `pulumi-cloudflare` | Go: `github.com/pulumi/pulumi-cloudflare/sdk/v6/go/cloudflare` | .NET: `Pulumi.Cloudflare`

## Core Principles

1. Use API tokens (not legacy API keys)
2. Store accountId in stack config
3. Match binding names across code/config
4. Use `module: true` for ES modules
5. Set `compatibilityDate` to lock behavior

## Authentication

Three methods (mutually exclusive). Preferred: API Token.

| Method | Env vars | Provider property |
|--------|----------|-------------------|
| API Token (recommended) | `CLOUDFLARE_API_TOKEN` | `apiToken` |
| API Key (legacy) | `CLOUDFLARE_API_KEY`, `CLOUDFLARE_EMAIL` | `apiKey` + `email` |
| API User Service Key | `CLOUDFLARE_API_USER_SERVICE_KEY` | `apiUserServiceKey` |

```typescript
const provider = new cloudflare.Provider("cf", { apiToken: process.env.CLOUDFLARE_API_TOKEN });
```

## Setup

**Pulumi.yaml:**

```yaml
name: my-cloudflare-app
runtime: nodejs
config:
  cloudflare:apiToken:
    value: ${CLOUDFLARE_API_TOKEN}
```

**Pulumi.\<stack\>.yaml** — store accountId per stack:

```yaml
config:
  cloudflare:accountId: "abc123..."
```

**index.ts:**

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";

const config = new pulumi.Config("cloudflare");
const accountId = config.require("accountId");
```

## Common Resource Types

| Resource | Purpose |
|----------|---------|
| `Provider` | Provider config |
| `WorkerScript` | Worker |
| `WorkersKvNamespace` | KV |
| `R2Bucket` | R2 |
| `D1Database` | D1 |
| `Queue` | Queue |
| `PagesProject` | Pages |
| `DnsRecord` | DNS |
| `WorkerRoute` | Worker route |
| `WorkersDomain` | Custom domain |

## Key Properties

- `accountId` - Required for most resources
- `zoneId` - Required for DNS/domain
- `name`/`title` - Resource identifier
- `*Bindings` - Connect resources to Workers

---

See: [patterns.md](./patterns.md), [gotchas.md](./gotchas.md)
