<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1551: Cursor models in OpenCode via pool-based proxy

**Session origin**: feature/dynamic-oauth-user-agent session (2026-03-21)
**Ref**: GH#5446

## What

Integrate Cursor model access into OpenCode by using our existing pool tokens and the `opencode-cursor-oauth` proxy/gRPC code — bypassing OpenCode's broken auth hook system entirely.

## Why

OpenCode v1.2.27 has two bugs that prevent the `opencode-cursor-oauth` plugin from working:
1. Auth hook `methods` arrays aren't invoked — OpenCode falls back to a generic API key prompt that stores `type: "api"` instead of `type: "oauth"`, so the plugin's loader returns `{}` immediately
2. Multiple plugins with auth hooks crash the TUI worker (array format not supported)

We already have working Cursor tokens in our pool file (`oauth-pool-helper.sh add cursor` reads from the local Cursor IDE). The proxy/gRPC translation code exists in `opencode-cursor-oauth`. We just need to wire them together inside our own plugin, bypassing OpenCode's auth system.

## How

### Architecture

Our `opencode-aidevops` plugin already runs at startup. Add a Cursor integration phase that:

1. **Read Cursor token from pool** — `~/.aidevops/oauth-pool.json` cursor accounts (already populated by `oauth-pool-helper.sh add cursor`)
2. **Refresh if expired** — re-read from Cursor IDE state DB (tokens are short-lived), or use the `refreshCursorToken` function from `opencode-cursor-oauth`
3. **Discover models** — use `getCursorModels()` from `opencode-cursor-oauth` (gRPC call to `api2.cursor.sh`, falls back to hardcoded list)
4. **Start local proxy** — use `startProxy()` from `opencode-cursor-oauth` (translates OpenAI-compatible requests to Cursor's protobuf/HTTP2 protocol)
5. **Register provider** — add `cursor` provider to OpenCode config with models pointing at `http://localhost:{port}/v1`
6. **Inject auth** — `client.auth.set()` with `type: "api"`, `key: "cursor-proxy"` (the proxy handles real auth internally)

### Key files from opencode-cursor-oauth to vendor/adapt

| File | Purpose | Adaptation needed |
|------|---------|-------------------|
| `src/proxy.ts` (1445 lines) | Local proxy: OpenAI format → Cursor gRPC | Use as-is, import from vendored copy |
| `src/models.ts` (193 lines) | Model discovery via gRPC + fallback list | Use as-is |
| `src/auth.ts` (142 lines) | Token refresh via `api2.cursor.sh` | Adapt to read from pool file instead of OpenCode auth store |
| `src/h2-bridge.mjs` (runtime) | HTTP/2 transport (Bun's http2 is broken) | Copy to dist as-is |
| `src/proto/` | Protobuf schemas | Copy as-is |
| `src/pkce.ts` | PKCE generation | Not needed (we don't do browser OAuth from the plugin) |

### Decision: vendor vs dependency

**Recommend vendoring** the relevant source files into `.agents/plugins/opencode-aidevops/cursor/` rather than depending on the npm package. Reasons:
- The npm package has the ESM extension bug (extensionless imports)
- We need to modify the auth flow (read from pool, not OpenCode auth store)
- The package is small (5 source files + proto schemas)
- Avoids the npm install step that OpenCode may or may not handle correctly

### Integration point in index.mjs

Add after the existing `initPoolAuth()` call:

```javascript
// Phase 8: Cursor proxy (t1551)
const cursorAccounts = getAccounts("cursor");
if (cursorAccounts.length > 0) {
  try {
    const { startCursorProxy } = await import("./cursor/proxy.js");
    const port = await startCursorProxy(cursorAccounts, client);
    // Register cursor provider with models pointing at localhost proxy
    console.error(`[aidevops] Cursor proxy started on port ${port}`);
  } catch (err) {
    console.error(`[aidevops] Cursor proxy failed: ${err.message}`);
  }
}
```

## Acceptance criteria

1. `oauth-pool-helper.sh add cursor` + restart OpenCode → Cursor models visible in Ctrl+T
2. Selecting a Cursor model and sending a message works (proxy translates to gRPC)
3. Our aidevops plugin continues to load normally (no crash from Cursor integration)
4. If no Cursor accounts in pool, the proxy doesn't start (no error, no resource usage)
5. If Cursor token is expired, it auto-refreshes from the IDE state DB or via `refreshCursorToken`
6. Tool calling works through the proxy (Cursor's native tools rejected, routed through OpenCode's MCP)

## Context

- Our fork: `~/Git/opencode-cursor` (branch `fix/esm-extensions` has the import fixes, `fix/graceful-loader-errors` has error handling)
- Upstream issues: anomalyco/opencode#18536 (auth arrays), ephraimduncan/opencode-cursor#15 (plugin crash)
- Our PR: ephraimduncan/opencode-cursor#16 (error handling)
- Pool file: `~/.aidevops/oauth-pool.json` — cursor accounts already work via `oauth-pool-helper.sh add cursor`
- The proxy uses `import.meta.dir` (Bun-only) for the H2 bridge path — this is fine since OpenCode runs on Bun
- Cursor tokens from the IDE state DB are short-lived JWTs — the proxy's token getter callback should re-read from the state DB or call `refreshCursorToken`
