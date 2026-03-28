# Terraform Troubleshooting & Best Practices

Common issues, security considerations, and best practices for the Cloudflare Terraform provider.

## Common Errors

### "Error: couldn't find resource"

**Cause**: Resource deleted outside Terraform

```bash
terraform import cloudflare_zone.example <zone-id>
# Or remove from state:
terraform state rm cloudflare_zone.example
```

### "409 Conflict" on worker deployment

**Cause**: Worker deployed by both Terraform and wrangler
**Fix**: Choose one deployment method. If using Terraform, remove wrangler deployments.

### DNS record already exists

**Cause**: Existing record not imported into Terraform

```bash
terraform import cloudflare_dns_record.example <zone-id>/<record-id>
```

### "Invalid provider configuration"

**Cause**: API token missing or invalid

```bash
export CLOUDFLARE_API_TOKEN="your-token"
# Or check token permissions in dashboard
```

### State locking errors

**Cause**: Multiple Terraform runs or stale lock

```bash
terraform force-unlock <lock-id>  # Use with caution
```

## Best Practices

### 1. Resource Naming

```hcl
locals { env_prefix = "${var.environment}-${var.project_name}" }

resource "cloudflare_worker_script" "api" { name = "${local.env_prefix}-api" }
resource "cloudflare_workers_kv_namespace" "cache" { title = "${local.env_prefix}-cache" }
```

### 2. Output Important Values

```hcl
output "zone_id" { value = cloudflare_zone.main.id; description = "Zone ID for DNS management" }
output "worker_url" { value = "https://${cloudflare_worker_domain.api.hostname}"; description = "Worker API endpoint" }
output "kv_namespace_id" { value = cloudflare_workers_kv_namespace.app.id; sensitive = false }
```

### 3. Use Data Sources for Existing Resources

```hcl
data "cloudflare_zone" "main" { name = var.domain }
data "cloudflare_accounts" "main" { name = var.account_name }

resource "cloudflare_worker_route" "api" {
  zone_id = data.cloudflare_zone.main.id
  # ...
}
```

### 4. Separate Secrets from Code

```hcl
# variables.tf
variable "cloudflare_api_token" {
  type = string; sensitive = true; description = "Cloudflare API token"
}

# terraform.tfvars (gitignored)
cloudflare_api_token = "actual-token-here"

# Or use environment variables: export TF_VAR_cloudflare_api_token="..."
```

### 5. Separate Directories per Environment

```text
environments/
  production/    # Separate state, separate vars
  staging/
  development/
```

Better than workspaces for isolation and clarity.

### 6. Remote State with Locking

```hcl
terraform {
  backend "s3" {
    bucket = "terraform-state"; key = "cloudflare/terraform.tfstate"; region = "us-east-1"
    dynamodb_table = "terraform-locks"; encrypt = true
  }
}
```

## Security Considerations

1. **Never commit secrets** — use variables + environment vars or secret management tools
2. **Scope API tokens** — create tokens with minimal required permissions
3. **Enable state encryption** — use encrypted S3 backend or Terraform Cloud
4. **Separate tokens per environment** — different tokens for prod/staging
5. **Rotate tokens regularly** — update tokens in CI/CD systems
6. **Review plans before apply** — always `terraform plan` first
7. **Use Access for sensitive apps** — don't expose admin panels publicly

## State Management

```bash
terraform state show cloudflare_zone.example   # Show resource details
terraform state mv cloudflare_zone.old cloudflare_zone.new  # Rename in state
terraform state pull > terraform.tfstate.backup  # Backup state
terraform state push terraform.tfstate           # Restore state
```

## Limits

| Resource | Limit | Notes |
|----------|-------|-------|
| API token rate limit | Varies by plan | Use `api_client_logging = true` to debug |
| Worker script size | 10 MB | Includes all dependencies |
| KV keys per namespace | Unlimited | Pay per operation |
| R2 storage | Unlimited | Pay per GB |
| D1 databases | 50,000 per account | Free tier: 10 |
| Pages projects | 500 per account | 100 for free accounts |
| DNS records | 3,500 per zone | Free plan |

## See Also

- [README](./README.md) - Provider setup
- [Patterns](./patterns.md) - Use cases
- Provider docs: <https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs>
