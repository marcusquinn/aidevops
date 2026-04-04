<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Security

## Secrets Management

```typescript
const config = new pulumi.Config();
const apiKey = config.requireSecret("apiKey");
const worker = new cloudflare.WorkerScript("worker", {
    accountId, name: "my-worker", content: code,
    secretTextBindings: [{name: "API_KEY", text: apiKey}],
});
// CLI: pulumi config set --secret apiKey "secret-value"
// Env: export CLOUDFLARE_API_TOKEN="..."
```

## API Token Scopes

Minimal permissions: Workers — `Workers Routes:Edit`, `Workers Scripts:Edit` | KV — `Workers KV Storage:Edit` | R2 — `R2:Edit` | D1 — `D1:Edit` | DNS — `Zone:Edit`, `DNS:Edit` | Pages — `Pages:Edit`

## State Security

Use Pulumi Cloud or S3 backend with encryption. Never commit state files to VCS. Use RBAC to control stack access.
