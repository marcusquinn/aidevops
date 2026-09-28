<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18520: Shared DataForSEO credential resolver for MCP, export and research helpers

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (follow-up to t18518/t18519)
- **Conversation context:** `keywords-helper.sh` now resolves DataForSEO credentials from gopass, but the other consumers only source `~/.config/aidevops/credentials.sh`. Operators who store credentials with `aidevops secret set` (the recommended path) get no credentials in those tools.

## What

One shared resolver provides `DATAFORSEO_USERNAME`/`DATAFORSEO_PASSWORD` to every DataForSEO consumer, in this order: environment → `credentials.sh` → gopass `aidevops/DATAFORSEO_API_LOGIN` + `aidevops/DATAFORSEO_API_PASSWORD` → legacy gopass `aidevops/DATAFORSEO_USERNAME` + `aidevops/DATAFORSEO_PASSWORD`. Values are never printed.

## Why

Plaintext `credentials.sh` is the fallback, not the recommended store. Today the DataForSEO MCP server, `seo-export-dataforseo.sh` and `keyword-research-helper-providers.sh` silently lack credentials when they live only in gopass.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/dataforseo-credentials.sh` — sourceable `dataforseo_load_credentials` with the order above; model on `_kw_load_credentials` in `.agents/scripts/keywords-helper.sh`.
- `EDIT: .agents/scripts/keywords-helper.sh` — `_kw_load_credentials` delegates to the shared function.
- `EDIT: .agents/scripts/seo-export-dataforseo.sh` — replace the `credentials.sh`-only load (around line 46) and update the help text (around lines 267-273).
- `EDIT: .agents/scripts/keyword-research-helper-providers.sh` — replace the three `credentials.sh` sources (around lines 42, 223, 279).
- `EDIT: .agents/plugins/opencode-aidevops/mcp-registry.mjs` — DataForSEO launch command (around line 260) sources the shared resolver instead of `credentials.sh`.
- `EDIT: .agents/scripts/lib/mcp_config.py` — `_register_dataforseo` (around line 134) uses the same launch command.
- `EDIT: .agents/scripts/setup-mcp-integrations.sh` — DataForSEO guidance (around lines 333-344) recommends `aidevops secret set DATAFORSEO_API_LOGIN|DATAFORSEO_API_PASSWORD`.
- `EDIT: .agents/scripts/setup/modules/mcp-setup.sh` — DataForSEO detection (around lines 846-853) uses the resolver.
- `EDIT: .agents/seo/dataforseo.md` — collapse the credential-source table to one row once all consumers share the resolver.

### Reference pattern

`_kw_load_credentials` in `.agents/scripts/keywords-helper.sh` (t18517/t18518) and gopass reads in `.agents/scripts/manyreach-helper.sh`.

### Files Scope

- .agents/scripts/dataforseo-credentials.sh
- .agents/scripts/keywords-helper.sh
- .agents/scripts/seo-export-dataforseo.sh
- .agents/scripts/keyword-research-helper-providers.sh
- .agents/plugins/opencode-aidevops/mcp-registry.mjs
- .agents/scripts/lib/mcp_config.py
- .agents/scripts/setup-mcp-integrations.sh
- .agents/scripts/setup/modules/mcp-setup.sh
- .agents/seo/dataforseo.md

## Verification

```bash
shellcheck .agents/scripts/dataforseo-credentials.sh .agents/scripts/keywords-helper.sh .agents/scripts/seo-export-dataforseo.sh .agents/scripts/keyword-research-helper-providers.sh
bash .agents/scripts/tests/test-keywords-helper.sh
# With a stub gopass on PATH serving only aidevops/DATAFORSEO_API_* dummy values, each consumer reaches the API (HTTP 401 for dummy values), never "credentials not set".
```

## Acceptance Criteria

- [ ] All listed consumers resolve credentials with the documented order.
- [ ] No consumer prints or logs credential values.
- [ ] Existing `credentials.sh` setups keep working unchanged.
- [ ] The OpenCode MCP entry starts with credentials stored only in gopass.
