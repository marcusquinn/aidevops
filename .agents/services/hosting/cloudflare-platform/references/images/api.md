# images API

> **Preferred: Cloudflare Code Mode MCP** _(experimental — see stability note below)_
>
> Management API endpoints for images are accessible via the Cloudflare Code Mode MCP server,
> which covers the full Cloudflare API (2,500+ endpoints) in ~1,000 tokens.
>
> Use `.agents/tools/mcp/cloudflare-code-mode.md` — call `search()` to discover endpoints,
> then `execute()` to call them.
>
> **Stability note:** `@cloudflare/codemode` is **Beta/experimental** and explicitly carries
> breaking-change risk. v0.1.0 (Feb 2026) removed `experimental_codemode()` and `CodeModeProxy`
> without a deprecation window. Pin to a specific semver in agent deployments and test before
> upgrading. Stable fallback: <https://developers.cloudflare.com/api>
