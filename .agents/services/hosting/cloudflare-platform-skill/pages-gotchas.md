<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gotchas

## Functions Not Running

1. **`_routes.json`**: May exclude Function routes
2. **File naming**: Must be `.js`/`.ts`, NOT `.jsx`/`.tsx`
3. **Build output**: Functions dir must be at root of output dir
4. **Precedence**: Functions always override redirects/static

## 404 on Static Assets

1. **Build output dir**: Must match actual build output setting
2. **Functions catching requests**: Use `_routes.json` to exclude static paths
3. **Advanced mode**: Must call `env.ASSETS.fetch()` or static won't serve

## Bindings Not Working

1. **wrangler.toml**: Check for TOML syntax errors
2. **Binding IDs**: Verify correct (especially KV/D1/R2)
3. **Local dev**: Check `.dev.vars` exists with correct values
4. **Regenerate types**: `npx wrangler types --path='./functions/types.d.ts'`
5. **Environment**: Production bindings ≠ preview bindings (set separately)

## Build Failures

1. **Logs**: Dashboard → Deployments → Build log
2. **Build command**: Verify correct for framework
3. **Output directory**: Must match actual build output
4. **Node version**: Set via `.nvmrc` or env var
5. **Env vars**: Settings → Environment variables
6. **Timeout**: 20min max
7. **Memory**: Can OOM on large projects

## Deployment Fails

1. **File count**: Max 20,000 files per deployment
2. **File size**: Max 25MB per file
3. **Validation**: `npx wrangler pages project validate`
4. **Bindings**: All referenced bindings must exist

## Middleware Not Running

1. **File location**: Must be `_middleware.ts` (underscore prefix)
2. **Export**: Must export `onRequest` or method-specific handlers
3. **Must call `next()`**: Or return Response directly
4. **Scope**: `functions/_middleware.ts` applies to ALL routes (including static)
5. **Order**: Array order matters: `[errorHandler, auth, logging]`

## Headers Not Applied

1. **`_headers` scope**: Only applies to static assets, not Functions
2. **Functions**: Must set headers via Response object
3. **Syntax**: Path line, then indented headers
4. **Limit**: Max 100 header rules

## Redirects Not Working

1. **Precedence**: Functions override redirects
2. **Syntax**: Check `_redirects` file format
3. **Limits**: 2,100 max (2,000 static + 100 dynamic)
4. **Query strings**: Preserved automatically

## TypeScript Errors

1. **Generate types**: `npx wrangler types` before dev
2. **tsconfig**: Point `types` to generated file
3. **Env interface**: Must match wrangler.toml bindings
4. **Type imports**: `import type { PagesFunction } from '@cloudflare/workers-types'`

## Local Dev Issues

1. **Port conflicts**: `--port=3000` to change
2. **Bindings**: Pass via CLI flags or wrangler.toml
3. **Persistence**: `--persist-to` to keep data between restarts
4. **Hot reload**: May need manual restart for some changes
5. **HTTPS**: Local dev = HTTP; production = HTTPS (affects cookies)

## Preview vs Production

1. **Bindings**: Set separately in Dashboard per environment
2. **Env vars**: Configure per environment
3. **Branch deploys**: Every branch gets preview deployment
4. **URLs**: `https://branch.project.pages.dev` vs `https://project.pages.dev`

## Performance

1. **Function invocations**: Exclude static assets via `_routes.json`
2. **Cold starts**: First request after deploy may be slower
3. **CPU time**: 10ms/request limit
4. **Memory**: 128MB limit (watch large JSON parsing)
5. **Bundle size**: Keep Functions < 1MB compressed

## Framework-Specific

| Framework | Adapter | Notes |
|-----------|---------|-------|
| Next.js | `@cloudflare/next-on-pages` | ISR + Middleware `waitUntil` unsupported — [compat matrix](https://github.com/cloudflare/next-on-pages/blob/main/docs/compatibility.md) |
| SvelteKit | `@sveltejs/adapter-cloudflare` | Set `platform: 'cloudflare'` in svelte.config.js |
| Remix | `@remix-run/cloudflare-pages` | Access bindings via server context |

## Debugging

```bash
# Tail live logs
npx wrangler pages deployment tail --project-name=my-project
```

```typescript
// In Function: log request + available bindings
console.log('Request:', { method: request.method, url: request.url });
console.log('Env keys:', Object.keys(env));
```

## Common Errors

| Error | Fix |
|-------|-----|
| "Module not found" | Bundle dependencies in build output |
| "Binding not found" | Verify wrangler.toml, regenerate types |
| "Request exceeded CPU limit" | Optimize hot paths; offload to Workers |
| "Script too large" | Tree-shake, dynamic imports, code-split |
| "Too many subrequests" | Batch calls; max 50/request |
| "KV key not found" | Check namespace (production vs preview) |
| "D1 error" | Verify database_id, check migrations applied |

## Limits

| Resource | Limit |
|----------|-------|
| Functions | 100k req/day (Free), 10ms CPU, 128MB mem, 1MB script |
| Deployments | 500/month (Free), 20k files, 25MB/file |
| Config | 2,100 redirects, 100 headers, 100 routes |
| Build | 20min timeout |
| Subrequests | 50/request |
| Request size | 100MB |

[Full limits](https://developers.cloudflare.com/pages/platform/limits/) · [Pages Docs](https://developers.cloudflare.com/pages/) · [Workers Examples](https://developers.cloudflare.com/workers/examples/)
