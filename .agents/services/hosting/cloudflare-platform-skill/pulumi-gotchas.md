# Troubleshooting & Best Practices

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Missing required property 'accountId'` | Account ID not set | Add to stack config or pass explicitly |
| Binding name mismatch | Worker expects `MY_KV` but binding differs | Match binding names in Pulumi and worker code |
| `resource 'abc123' not found` | Resource missing in account/zone | Ensure resource exists in correct account/zone |
| API token permissions error | Token lacks required scopes | Verify token has Workers, KV, R2, D1 permissions |

## Debugging

```bash
pulumi up --logtostderr -v=9   # verbose logging
pulumi preview                  # preview changes
pulumi stack export             # view resource state
pulumi stack --show-urns
pulumi state delete <urn>       # use with caution
```

## Best Practices

**Stack configuration:**

```yaml
# Pulumi.<stack>.yaml
config:
  cloudflare:accountId: "abc123"
  cloudflare:apiToken:
    secure: "encrypted-value"
  app:domain: "example.com"
  app:zoneId: "xyz789"
```

**Explicit provider configuration** (multi-account):

```typescript
const devProvider = new cloudflare.Provider("dev", {apiToken: devToken});
const prodProvider = new cloudflare.Provider("prod", {apiToken: prodToken});
const devWorker = new cloudflare.WorkerScript("dev-worker", {
    accountId: devAccountId, name: "worker", content: code,
}, {provider: devProvider});
```

**Resource naming** — prefix with stack name:

```typescript
const stack = pulumi.getStack();
const kv = new cloudflare.WorkersKvNamespace(`${stack}-kv`, {accountId, title: `${stack}-my-kv`});
```

**Protect production resources:**

```typescript
const prodDb = new cloudflare.D1Database("prod-db", {accountId, name: "production-database"},
    {protect: true});
```

**Dependency ordering:**

```typescript
const migration = new command.local.Command("migration", {
    create: pulumi.interpolate`wrangler d1 execute ${db.name} --file ./schema.sql`,
}, {dependsOn: [db]});
const worker = new cloudflare.WorkerScript("worker", {
    accountId, name: "worker", content: code,
    d1DatabaseBindings: [{name: "DB", databaseId: db.id}],
}, {dependsOn: [migration]});
```

## Security

**Secrets management:**

```typescript
const config = new pulumi.Config();
const apiKey = config.requireSecret("apiKey");
const worker = new cloudflare.WorkerScript("worker", {
    accountId, name: "my-worker", content: code,
    secretTextBindings: [{name: "API_KEY", text: apiKey}],
});
// pulumi config set --secret apiKey "secret-value"
// export CLOUDFLARE_API_TOKEN="..."
```

**API token scopes** (minimal permissions): Workers — `Workers Routes:Edit`, `Workers Scripts:Edit` | KV — `Workers KV Storage:Edit` | R2 — `R2:Edit` | D1 — `D1:Edit` | DNS — `Zone:Edit`, `DNS:Edit` | Pages — `Pages:Edit`

**State security:** Use Pulumi Cloud or S3 backend with encryption. Never commit state files to VCS. Use RBAC to control stack access.

## Performance

- Avoid storing large files in state; use `ignoreChanges` for frequently changing properties
- Pulumi automatically parallelizes independent resource updates
- `pulumi refresh --yes` — sync state with actual infrastructure

## Migration

**Import existing resources:**

```bash
pulumi import cloudflare:index/workerScript:WorkerScript my-worker <account_id>/<worker_name>
pulumi import cloudflare:index/workersKvNamespace:WorkersKvNamespace my-kv <namespace_id>
pulumi import cloudflare:index/r2Bucket:R2Bucket my-bucket <account_id>/<bucket_name>
```

**From Terraform/Wrangler:** Use `pulumi import`, rewrite configs in Pulumi DSL, verify with `pulumi preview`, then switch deployments.

## CI/CD

Use `pulumi/actions@v4` (GitHub) or `pulumi/pulumi:latest` image (GitLab). Required secrets:

| Secret | Purpose |
|--------|---------|
| `PULUMI_ACCESS_TOKEN` | Pulumi Cloud state backend |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API access |

```yaml
# GitHub Actions minimal pattern
- uses: pulumi/actions@v4
  with: {command: up, stack-name: prod}
  env:
    PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
    CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

GitLab: `pulumi stack select prod && pulumi up --yes` with the same env vars.

## Resources

[Pulumi Registry](https://www.pulumi.com/registry/packages/cloudflare/) · [API Docs](https://www.pulumi.com/registry/packages/cloudflare/api-docs/) · [GitHub](https://github.com/pulumi/pulumi-cloudflare) · [Cloudflare Workers Docs](https://developers.cloudflare.com/workers/)
