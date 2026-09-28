---
description: "Cloudflare cf CLI (open beta) — agent-first CLI generated from the full Cloudflare API (~3,000 operations), JSON by default, intent search, cloudflare.config.ts, Vite dev/build/deploy, and Wrangler migration"
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare cf CLI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: offered by interactive `setup.sh` (step "Setup Cloudflare cf CLI"), or `npm i -g cf` (Node.js >= 22; binaries `cf` and `cloudflare`). Open beta; verified with `1.0.0-beta.5`.
- **Updates**: tracked by `aidevops update-tools` and the auto-updater (`tool-version-check.sh`, prerelease-aware).
- **Coverage**: generated from Cloudflare's public OpenAPI surface; shape `cf <product> [group…] <operation>`.
- **Discover commands**: `cf cli search "<action + resource type>"` returns five JSON matches. Do not walk nested `--help`.
- **Inspect a request**: `cf schema <command…>` (method, path, params, body fields); `--dry-run` prints the resolved request without sending it.
- **Output**: structured results are JSON on stdout; filter with `jq`. `CF_QUIET=1` or piping disables progress animation.
- **Auth precedence**: `CLOUDFLARE_API_TOKEN` env var, then OAuth profile (`--profile`, directory binding via `cf auth activate`, or default from `cf auth login`).
- **Other env**: `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ZONE_ID` (or `-z/--zone <id|domain>`).
- **Projects**: `cf init [dir]`, `cf dev`, `cf build`, `cf deploy [--dry-run]`, `cf migrate [--dry-run]`; config is `cloudflare.config.ts`.
- **Telemetry**: on by default. `cf cli telemetry disable`, or `CF_SEND_TELEMETRY=false` / `DO_NOT_TRACK=1` per run.
- **Source**: repo `cloudflare/cf`; launch post https://blog.cloudflare.com/cloudflare-cf-cli-launch/

<!-- AI-CONTEXT-END -->

## When to Use

| Intent | Tool |
|--------|------|
| Manage account/zone resources (DNS, WAF, zones, R2, Access, registrar, analytics) from a shell | `cf` (this file) when installed |
| Same, but `cf` is unavailable, or you need to batch many calls in one sandboxed script | `tools/mcp/cloudflare-code-mode.md` |
| New Worker or Vite-based Worker project | `cf init` / `cf dev` / `cf deploy` |
| Existing Wrangler project that uses esbuild, or Rust/Python Workers | Keep Wrangler (`services/hosting/cloudflare-platform-skill/wrangler.md`); `cf` delegates to it |
| Product architecture, bindings, runtime patterns | `services/hosting/cloudflare-platform-skill.md` |

Detect the project type before choosing: `cloudflare.config.ts` means `cf`; `wrangler.toml`/`wrangler.json[c]` means Wrangler until migrated.

## Agent Workflow

1. `command -v cf` — if missing, fall back to Code Mode MCP, or suggest re-running `setup.sh` / `npm i -g cf`.
2. `cf cli search "list DNS records for a zone"` — pick the best match; don't repeat near-identical searches.
3. `cf <command> --help` for flags, `cf schema <command>` for the exact API request.
4. For writes, run with `--dry-run` first, then execute and re-read the resource to verify.

Keep `cf cli search` queries anonymous: describe the action and resource type only, never names, domains, emails, IDs or tokens. The CLI requests this, and search queries are recorded in usage telemetry unless it is disabled.

## Auth with aidevops Secrets

`cf` reads `CLOUDFLARE_API_TOKEN`. Inject a stored token without exposing it (replace `<NAME>` with the secret name from `aidevops secret list`):

```bash
aidevops secret <NAME> -- sh -c 'CLOUDFLARE_API_TOKEN="$<NAME>" cf zones list --per-page 5 | jq length'
```

Interactive users can instead run `cf auth login` (OAuth device flow) and bind per-directory profiles with `cf auth create <name>` + `cf auth activate <name> [dir]`. Token scoping and rotation: `services/hosting/cloudflare.md`.

## Projects

- `cf init my-worker --no-install` scaffolds `cloudflare.config.ts`, `vite.config.ts`, `src/index.ts`, `tsconfig.json`, `package.json` (scripts `dev`/`build`/`deploy`/`typecheck`), `.gitignore`. Use `cf init .` in scripts; without a directory it prompts.
- `cf build` delegates to `vite build` and writes standardized output to `.cloudflare/output/v0/`.
- `cf deploy` builds then uploads; `--prebuilt` reuses existing output. `--dry-run` works without credentials for this flow.
- `cf dev` delegates to `npx vite` (default port 5173). In agent sessions it prints Local Explorer API routes (`/cdn-cgi/local/explorer/api/...`) for bindings, storage, and read-only trace/log SQL queries.
- `cf migrate [path] --dry-run` previews Wrangler → `cloudflare.config.ts` conversion. `--bundler vite|wrangler` (default vite only when `@cloudflare/vite-plugin` is declared); refuses a dirty Git worktree unless `--force`.
- `--local` runs supported KV/D1/R2 commands against persisted local Miniflare state (`~/.config/cloudflare/state`, override with `--persist-to`).

## Gotchas (verified on 1.0.0-beta.5)

- `cf auth whoami` can report `"tokenValid": false` for a scoped API token that still works; confirm with a read-only call such as `cf zones list --per-page 1`.
- `cf dev` cannot forward extra arguments (for example `--port`) to Vite yet; set them in `vite.config.ts` or run `npx vite` directly.
- `--dry-run` does not resolve a domain passed to `--zone` into a zone ID; the preview URL contains the domain verbatim.
- npm reports that the `workerd` postinstall script was not approved; `cf build`, `cf deploy --dry-run` and `cf dev` still worked. Approve it (`npm approve-scripts workerd`) only if local runtime errors point to it.
- The binary name `cf` collides with the Cloud Foundry CLI. If `cf --version` does not print the Cloudflare banner, use the `cloudflare` alias. Setup and update-tools detect Cloud Foundry (`cf version 8.x`) and never replace it.
- Generated delete commands decline by default when non-interactive and point to `--force`; pass it only after a `--dry-run` and explicit authorization.
- Beta surface changes with each pinned OpenAPI release. Generator/CLI issues are recorded under `test_bugs/` in the `cloudflare/cf` repo, each with a `status:` field (open or fixed); check there before debugging odd behaviour.
- Wrangler stays maintained for 18 months after the beta ends; don't rewrite working Wrangler projects without a reason.
