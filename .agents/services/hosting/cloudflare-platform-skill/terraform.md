<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Terraform Provider

**Rules:** Provider-first (never mix with wrangler.toml for same resources) · Remote state always (S3/Terraform Cloud) · Modular (zones, workers, pages) · Pin with `~>` · Secrets via env vars, never hardcoded

## Provider Setup

```hcl
terraform {
  required_version = ">= 1.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.15.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token  # or CLOUDFLARE_API_TOKEN env var
}
```

**Auth (priority order):**
1. **API Token** (recommended): `api_token` / `CLOUDFLARE_API_TOKEN` — Dashboard → My Profile → API Tokens; scope to specific accounts/zones
2. **Global API Key** (legacy): `api_key` + `api_email` / `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` — less secure
3. **User Service Key**: `user_service_key` — Origin CA certificates only

**Remote state backend:**

```hcl
terraform {
  backend "s3" {
    bucket = "terraform-state"
    key    = "cloudflare/terraform.tfstate"
    region = "us-east-1"
  }
}
```

## Common Commands

```bash
terraform init          # Initialize provider
terraform plan          # Plan changes
terraform apply         # Apply changes
terraform destroy       # Destroy resources
terraform import cloudflare_zone.example <zone-id>  # Import existing
terraform state list    # List resources in state
terraform fmt -recursive && terraform validate      # Format + validate
```

## See Also

- [Patterns & Use Cases](./terraform-patterns.md) — multi-env, CI/CD, worker bindings, load balancing
- [Troubleshooting & Best Practices](./terraform-gotchas.md) — common errors, security, state management
