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

**Commands**: `pnpm dev` (all) · `pnpm build` (all) · `pnpm --filter web dev` (single) · `pnpm --filter @workspace/ui build` (full name) · `pnpm --filter web... build` (+ deps)

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

### Package.json Exports

```json
// packages/ui/web/package.json
{
  "name": "@workspace/ui-web",
  "exports": {
    ".": "./src/index.ts",
    "./globals.css": "./src/styles/globals.css",
    "./*": "./src/components/*.tsx"
  }
}
```

```tsx
import { Button } from "@workspace/ui-web/button";
import { cn } from "@workspace/ui-web";
import "@workspace/ui-web/globals.css";
```

### Workspace Dependencies

Use `"workspace:*"` protocol (not `"*"`):

```json
{ "dependencies": { "@workspace/ui-web": "workspace:*", "@workspace/api": "workspace:*" } }
```

### Filtering

```bash
pnpm --filter web dev                  # single
pnpm --filter web... build             # + dependencies
pnpm --filter ...web build             # + dependents
pnpm --filter web --filter mobile dev  # multiple
pnpm --filter "./packages/*" build     # by directory
pnpm --filter "!web" build             # exclude
```

### Environment Variables

```bash
# "with-env" loads .env via dotenv-cli before turbo (equivalent: pnpm dotenv -- turbo build)
pnpm with-env turbo build
```

```json
{ "scripts": { "build": "pnpm with-env turbo build", "dev": "pnpm with-env turbo dev" } }
```

### Shared TypeScript Config

```json
// tooling/typescript/base.json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "compilerOptions": {
    "strict": true, "moduleResolution": "bundler", "module": "ESNext",
    "target": "ES2022", "lib": ["ES2022"], "skipLibCheck": true, "esModuleInterop": true
  }
}
// packages/api/tsconfig.json
{ "extends": "@workspace/tsconfig/base.json", "compilerOptions": { "outDir": "dist" }, "include": ["src"] }
```

### Shared ESLint Config

```js
// tooling/eslint/base.js
module.exports = { extends: ["eslint:recommended", "prettier"], rules: {} };
// apps/web/eslint.config.js
import baseConfig from "@workspace/eslint-config/base";
export default [...baseConfig];
```

### Database Package

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
