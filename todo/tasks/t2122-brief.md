# t2122: Extend Response.json() fix to remaining opencode plugin Bun.serve callers

**Session origin:** interactive (follow-up filed during `/review-issue-pr 19174` with marcusquinn)

**Ref:** GH#19175 | **Parent:** PR #19174 (superdav42, claude+google proxy fix)

## What

Stop the `Expected a Response object, but received '_Response'` error from
recurring in the three opencode plugin files that PR #19174 does not touch.
Introduce a shared `response-helpers.mjs` module so the fix lives in exactly
one place for the whole plugin, and route the untouched call sites through
it.

Files changed:

- NEW: `.agents/plugins/opencode-aidevops/response-helpers.mjs` — shared
  `jsonResponse(data, init?)` and `textResponse(body, init?)` helpers with a
  cross-realm-safe path (`Response.json()` when available) and a
  documented fallback. Source of truth for the workaround.
- EDIT: `.agents/plugins/opencode-aidevops/cursor/proxy.js` — 5 `new Response(...)`
  call sites migrated (4 `jsonResponse`, 1 `textResponse` 404). Adds one
  import line.
- EDIT: `.agents/plugins/opencode-aidevops/cursor/proxy-stream.js` — 1 SSE
  streaming response routed through `textResponse` for consistency.
- EDIT: `.agents/plugins/opencode-aidevops/provider-auth-request.mjs` — 1
  streaming passthrough routed through `textResponse`.
- NEW: `tests/test-opencode-response-helpers.sh` — smoke test (syntax-check
  + runtime behaviour assertions for `jsonResponse`/`textResponse`).

**Out of scope (deferred to a follow-up after #19174 merges):**

- `.agents/plugins/opencode-aidevops/claude-proxy.mjs` and `google-proxy.mjs`
  currently duplicate `jsonResponse`/`textResponse` locally (as introduced
  by #19174). They should eventually import from `response-helpers.mjs`
  instead, but that migration has to wait until #19174 merges to avoid a
  trivial merge conflict. A follow-up PR will delete the two local copies
  and add the import. This PR deliberately does not touch those files.

## Why

PR #19174 (landing the `Response.json()` fix for claude-proxy and
google-proxy) is a strict net improvement with 42 minutes of clean journal
evidence, but the same idiom exists in four other files in the same plugin:
`cursor/proxy.js` (with its own `Bun.serve` at line 160), `cursor/proxy-stream.js`,
and `provider-auth-request.mjs`. If the author's root-cause hypothesis
(plugin loader rebinds `Response` to a realm-local `_Response`) is correct,
these are dormant time-bombs — any user who enables the Cursor provider
will hit the exact same journal spam as soon as the proxy handles a
`/v1/models` request or a non-streaming completion.

Rather than ship another round of "fix it where the user reported it", this
task:

1. Factors the helper out of the two files that `#19174` duplicates it into,
   so the plugin has a single audited call site for the workaround.
2. Applies the helper to the three new files. The JSON call sites in
   `cursor/proxy.js` are the real fix; the `textResponse` migrations on the
   streaming paths are consistency-only (streaming has never been observed
   to trip the mismatch in practice, per `#19174`'s own evidence), but
   funnel all response construction through the same module so a future
   workaround lands in one place.

## How

1. **Memory + discovery pass done** — `git log` on the plugin shows no
   in-flight work on these files (#19164 was a stream-chunking fix in a
   different file; #18906 was the decomposition that created `cursor/proxy.js`
   as a standalone). Memory had no prior entries for this class of bug.

2. **Create `response-helpers.mjs`** with `jsonResponse` using `Response.json`
   when available and a `new Response(JSON.stringify(...))` fallback
   matching the Content-Type header pattern from #19174. `textResponse` is
   a thin alias over `new Response(...)` kept for consistency — the module
   docstring documents the empirical observation that streaming paths have
   not been affected and the alias exists to centralise the fix if that
   ever changes.

3. **Migrate cursor/proxy.js** — add one import line, replace 5 call sites.
   Model the call-site shape on #19174's transformations in `claude-proxy.mjs`
   (e.g., error payloads collapse `{status, headers: {Content-Type: ...}}`
   to `{status}` since `jsonResponse` sets the header itself).

4. **Migrate cursor/proxy-stream.js** and **provider-auth-request.mjs** —
   add one import each, replace 1 call site each with `textResponse`.
   These streaming paths have not been observed to fail, but consistency
   is cheap and the alias is free.

5. **Test** — `tests/test-opencode-response-helpers.sh` runs `node --check`
   on all four files plus a runtime assertion that `jsonResponse` and
   `textResponse` return valid `Response` objects, round-trip JSON and text
   bodies, honour custom status codes, and accept `ReadableStream` bodies.
   Shellcheck clean. Real acceptance is the OpenCode journal — see below.

## Acceptance criteria

- [x] `response-helpers.mjs` exists and exports `jsonResponse`, `textResponse`
- [x] `cursor/proxy.js` has zero `new Response(...)` call sites; all 5 routed through helpers
- [x] `cursor/proxy-stream.js` SSE response routed through `textResponse`
- [x] `provider-auth-request.mjs` streaming passthrough routed through `textResponse`
- [x] `node --check` clean on all four modified files
- [x] `tests/test-opencode-response-helpers.sh` passes (5 assertions)
- [x] `shellcheck` clean on the new test script
- [ ] **Runtime verification (pending user):** after merge, restart
      `opencode-web.service` and tail the journal for 30+ minutes without
      seeing `Expected a Response object, but received '_Response'`.
      Parallel to #19174's existing 42-min clean run.
- [x] Does NOT touch `claude-proxy.mjs` or `google-proxy.mjs` (follow-up
      consolidation deferred until #19174 merges)

## Context

- **Parent PR:** #19174 — original `Response.json()` fix for claude+google.
  42-min clean runtime, mergeable, approve gate satisfied.
- **Root cause (not fixable here):** OpenCode's Bun plugin loader runs
  plugin code in a context where `globalThis.Response` may resolve to a
  different class identity than the one `Bun.serve`'s native fetch
  dispatcher type-checks against. This is an upstream OpenCode/Bun
  interaction; our fix is a stable symptom workaround.
- **Why `Response.json()` works:** static Fetch API method implemented
  natively in Bun, bypasses the user-visible constructor and returns an
  instance blessed by Bun's internal path.
- **Why the streaming `textResponse` migration is consistency-only:**
  PR #19174's own helper uses raw `new Response()` for streaming bodies
  and has a 42-min clean run, suggesting the bug is specific to the
  JSON-stringify + Content-Type init shape, not streaming. The alias
  gives us a single call site to patch if we ever see otherwise.
- **Tier:** `tier:simple` — verbatim oldString/newString replacements in
  4 files, one new file under 100 lines, clear acceptance criteria,
  single-estimate under 1h.
