---
description: Turborepo monorepo build system - workspaces, caching, pipelines
mode: subagent
tools: [read, write, edit, bash, glob, grep, webfetch, task, context7_*]
---

# Turborepo - Monorepo Build System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: High-performance build system for JS/TS monorepos
- **Package Manager**: pnpm (recommended), npm, yarn
- **Docs**: [turbo.build/repo/docs](https://turbo.build/repo/docs) (via Context7 MCP) · **Features**: Incremental caching · Parallel execution · Remote caching (Vercel)

**Commands**: `pnpm dev` · `pnpm build` · `pnpm --filter web dev` · see Filtering section for full syntax

**Structure**:

```text
apps/     (web, mobile, extension)
packages/ (ui, api, db, auth, i18n, shared)
tooling/  (eslint, typescript, prettier)
```

**Package Naming**:

| Location | Name Pattern | Import |
|----------|--------------|--------|
| `packages/ui/web` | `@workspace/ui-web` | `@workspace/ui-web/button` |
| `packages/db` | `@workspace/db` | `@workspace/db/schema` |
| `tooling/eslint` | `@workspace/eslint-config` | `@workspace/eslint-config` |

**turbo.json**:

```json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build":     { "dependsOn": ["^build"], "outputs": [".next/**", "dist/**"] },
    "dev":       { "cache": false, "persistent": true },
    "lint":      { "dependsOn": ["^build"] },
    "typecheck": { "dependsOn": ["^build"] }
  }
}
```

<!-- AI-CONTEXT-END -->

## Patterns

### Filtering

```bash
pnpm dev                               # all packages
pnpm build                             # all packages
pnpm --filter web dev                  # single package
pnpm --filter @workspace/ui build      # by full name
pnpm --filter web... build             # package + dependencies
pnpm --filter ...web build             # package + dependents
pnpm --filter web --filter mobile dev  # multiple
pnpm --filter "./packages/*" build     # by directory
pnpm --filter "!web" build             # exclude
```

### Package.json Exports

```json
// packages/ui/web/package.json
{ "name": "@workspace/ui-web", "exports": { ".": "./src/index.ts", "./globals.css": "./src/styles/globals.css", "./*": "./src/components/*.tsx" } }
```

```tsx
import { Button } from "@workspace/ui-web/button";
import { cn } from "@workspace/ui-web";
import "@workspace/ui-web/globals.css";
```

### Workspace Dependencies

Use `"workspace:*"` protocol (not `"*"`): `{ "dependencies": { "@workspace/ui-web": "workspace:*" } }`

### Environment Variables

Load `.env` before turbo with `dotenv-cli`: `pnpm with-env turbo build`

Root package.json scripts: `"build": "pnpm with-env turbo build"`, `"dev": "pnpm with-env turbo dev"`

### Shared Configs

**TypeScript** — extend from `@workspace/tsconfig/base.json`. Key settings: `strict: true`, `moduleResolution: "bundler"`, `module: "ESNext"`, `target: "ES2022"`, `skipLibCheck: true`.

Per-package: `{ "extends": "@workspace/tsconfig/base.json", "compilerOptions": { "outDir": "dist" }, "include": ["src"] }`

**ESLint** — base config at `tooling/eslint/base.js`, extend per-app:

```js
import baseConfig from "@workspace/eslint-config/base";
export default [...baseConfig];
```

### Database Package

Separate public API from server-only exports:

```tsx
// packages/db/src/index.ts — public API
export * from "./schema";
export type { InferSelectModel, InferInsertModel } from "drizzle-orm";
// packages/db/src/server.ts — server-only
export { db } from "./client";
```

```bash
pnpm --filter @workspace/db db:generate  # generate migrations
pnpm --filter @workspace/db db:migrate   # apply
pnpm --filter @workspace/db db:studio    # open studio UI
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Circular dependencies (A→B→A) | Extract shared code to a third package |
| Missing `^` in `dependsOn` | `"^build"` = dependencies first; `"build"` = same package only |
| Cache not invalidating | Check `outputs` in turbo.json; add env vars to `globalEnv` |
| Wrong workspace protocol | Use `"workspace:*"` not `"*"` |
| TypeScript path issues | Use `moduleResolution: "bundler"`; match `exports` in package.json |

## Related

- `tools/api/drizzle.md` — Database in monorepo
- `tools/ui/nextjs-layouts.md` — App structure
- Context7 MCP for Turborepo documentation
