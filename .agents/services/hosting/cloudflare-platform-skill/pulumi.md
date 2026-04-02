# Cloudflare Pulumi Provider

Expert guidance for Cloudflare Pulumi Provider (@pulumi/cloudflare) v6.x. Programmatic management of Workers, Pages, D1, KV, R2, DNS, Queues, etc.

**Packages:** `@pulumi/cloudflare` (TS/JS) · `pulumi-cloudflare` (Python) · `github.com/pulumi/pulumi-cloudflare/sdk/v6/go/cloudflare` (Go) · `Pulumi.Cloudflare` (.NET)

## Core Principles

1. Use API tokens (not legacy API keys)
2. Store accountId in stack config
3. Match binding names across code/config
4. Use `module: true` for ES modules
5. Set `compatibilityDate` to lock behavior

## Authentication

Three methods (mutually exclusive). Prefer API Token.

```typescript
import * as cloudflare from "@pulumi/cloudflare";

// 1. API Token (Recommended) — env: CLOUDFLARE_API_TOKEN
const provider = new cloudflare.Provider("cf", { apiToken: process.env.CLOUDFLARE_API_TOKEN });

// 2. API Key (Legacy) — env: CLOUDFLARE_API_KEY, CLOUDFLARE_EMAIL
const provider = new cloudflare.Provider("cf", { apiKey: process.env.CLOUDFLARE_API_KEY, email: process.env.CLOUDFLARE_EMAIL });

// 3. API User Service Key — env: CLOUDFLARE_API_USER_SERVICE_KEY
const provider = new cloudflare.Provider("cf", { apiUserServiceKey: process.env.CLOUDFLARE_API_USER_SERVICE_KEY });
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

**Key properties:** `accountId` (required for most), `zoneId` (DNS/domain), `name`/`title` (identifier), `*Bindings` (connect resources to Workers)

---

See: [patterns.md](./patterns.md), [gotchas.md](./gotchas.md)
