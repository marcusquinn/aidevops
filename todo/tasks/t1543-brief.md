<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1543: OAuth Multi-Account Pool Plugin

## Session Origin

Interactive session — user requested implementation after analysis of OpenCode PR #11832 (multi-account OAuth rotation). Determined that the existing OpenCode plugin API supports building this at the plugin layer without waiting for the upstream PR.

## What

Add an OAuth multi-account pool module to the existing `opencode-aidevops` plugin (`~/.aidevops/agents/plugins/opencode-aidevops/`) that:

1. Registers a custom provider (`anthropic-pool`) via the plugin `auth` hook
2. Stores multiple OAuth credentials in `~/.aidevops/oauth-pool.json` keyed by account email
3. Rotates credentials on rate limits (429) via a custom `fetch` wrapper
4. Manages token refresh automatically using refresh tokens
5. Provides `/model-accounts-pool` custom tool for account management (list, remove)
6. Mirrors all Anthropic models under the pool provider

## Why

- OAuth subscriptions (Claude Pro/Max) are significantly cheaper than API keys
- Single-account OAuth hits rate limits mid-session with no recovery
- OpenCode PR #11832 has been open 6+ weeks with no maintainer review
- The plugin API already supports everything needed — no fork required
- Benefits both interactive and headless sessions

## How

### New file: `oauth-pool.mjs`

Module in `~/.aidevops/agents/plugins/opencode-aidevops/` containing:

- `ANTHROPIC_MODELS` — model definitions mirroring built-in Anthropic provider
- `loadPool()` / `savePool()` — read/write `~/.aidevops/oauth-pool.json`
- `authorize()` — PKCE OAuth flow (reuses client ID from `opencode-anthropic-auth`)
- `exchange()` — code-to-token exchange
- `refreshToken()` — refresh expired access tokens
- `createPoolFetch()` — fetch wrapper with rotation on 429/401
- `poolAuthHook` — the `auth` hook export for the plugin
- `createPoolTool()` — the `/model-accounts-pool` tool definition

### Integration in `index.mjs`

- Import `poolAuthHook` and `createPoolTool` from `oauth-pool.mjs`
- Add to the plugin's returned hooks object
- Register pool provider models in the `config` hook

### Pool file format (`~/.aidevops/oauth-pool.json`)

```json
{
  "anthropic": [
    {
      "email": "user@example.com",
      "refresh": "...",
      "access": "...",
      "expires": 1711234567,
      "added": "2026-03-19T...",
      "lastUsed": "2026-03-19T...",
      "status": "active",
      "rateLimitUntil": null
    }
  ]
}
```

### Key design decisions

- Separate pool file (not `auth.json`) — survives OpenCode updates, no conflict with built-in auth
- Email as account identifier — natural key, what users recognise
- Same OAuth client ID as built-in plugin — public PKCE client, no secret needed
- `fetch` wrapper approach (not `chat.headers`) — gives full control over retry logic
- Provider name `anthropic-pool` — coexists with built-in `anthropic` provider

## Acceptance Criteria

1. User can run `opencode auth login`, select "Anthropic Pool", and add an account via OAuth
2. Running login again adds a second account (not replaces)
3. When one account hits 429, the next request uses the next account automatically
4. `/model-accounts-pool` lists all accounts with status (active, idle, rate-limited)
5. `/model-accounts-pool remove user@example.com` removes an account from the pool
6. All Anthropic models appear under the `anthropic-pool` provider in the model picker
7. Token refresh works automatically when access tokens expire
8. Pool file has 0600 permissions (contains OAuth tokens)
9. ShellCheck/linting passes on all modified files

## Context

- Built-in auth plugin source: `/tmp/anthropic-auth/package/index.mjs` (extracted during analysis)
- Plugin API types: `/tmp/package/dist/index.d.ts` (extracted `@opencode-ai/plugin@1.2.27`)
- Existing plugin: `~/.aidevops/agents/plugins/opencode-aidevops/index.mjs`
- OpenCode provider loading: `packages/opencode/src/provider/provider.ts` lines 978-993
