# terraform API

> **IaC tool — Cloudflare API is abstracted by the Terraform provider**
>
> The Cloudflare Terraform provider calls the Cloudflare management API internally.
> You do not call Cloudflare API endpoints directly when using Terraform — the provider
> handles that based on your HCL resource definitions.
>
> For Cloudflare Terraform provider resources and data sources see:
> https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs
>
> To call Cloudflare management API endpoints directly (without Terraform), use the
> Cloudflare Code Mode MCP — see `.agents/tools/mcp/cloudflare-code-mode.md`.
