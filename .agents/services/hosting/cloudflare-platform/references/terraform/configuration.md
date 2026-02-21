# terraform Configuration

> **IaC tool — configuration is HCL files, not a direct REST API surface**
>
> Terraform with the Cloudflare provider manages Cloudflare resources declaratively via HCL.
> The Cloudflare Terraform provider wraps the Cloudflare API internally; there are no
> Terraform-specific REST endpoints to discover with Code Mode MCP.
>
> For Cloudflare Terraform provider resource configuration see:
> https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs
>
> To call Cloudflare management API endpoints directly (without Terraform), use the
> Cloudflare Code Mode MCP — see `.agents/tools/mcp/cloudflare-code-mode.md`.
