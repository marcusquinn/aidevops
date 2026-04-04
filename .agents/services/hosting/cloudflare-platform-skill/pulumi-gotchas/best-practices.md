<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Best Practices

## Stack Configuration

```yaml
# Pulumi.<stack>.yaml
config:
  cloudflare:accountId: "abc123"
  cloudflare:apiToken:
    secure: "encrypted-value"
  app:domain: "example.com"
  app:zoneId: "xyz789"
```

## Protect Production Resources

```typescript
const prodDb = new cloudflare.D1Database("prod-db", {accountId, name: "production-database"},
    {protect: true});
```

## Dependency Ordering

```typescript
const migration = new command.local.Command("migration", {
    create: pulumi.interpolate`wrangler d1 execute ${db.name} --file ./schema.sql`,
}, {dependsOn: [db]});
const worker = new cloudflare.WorkerScript("worker", {
    accountId, name: "worker", content: code,
    d1DatabaseBindings: [{name: "DB", databaseId: db.id}],
}, {dependsOn: [migration]});
```

For multi-account providers, resource naming, and environment patterns, see [../pulumi-patterns.md](../pulumi-patterns.md).
