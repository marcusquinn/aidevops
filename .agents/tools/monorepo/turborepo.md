---
description: Turborepo monorepo build system - workspaces, caching, pipelines
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# Turborepo - Monorepo Build System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: High-performance build system for JavaScript/TypeScript monorepos
- **Package Manager**: pnpm (recommended), npm, yarn
- **Docs**: Use Context7 MCP for current documentation

**Key Features**:
- Incremental builds with caching
- Parallel task execution
- Remote caching (Vercel)
- Dependency-aware task ordering

**Common Commands**:

```bash
# Run dev for all packages
pnpm dev

# Run build for all packages
pnpm build

# Run specific task for specific package
pnpm --filter web dev
pnpm --filter @workspace/ui build

# Run task for package and its dependencies
pnpm --filter web... build
```

**Workspace Structure**:

```text
/
├── apps/
│   ├── web/              # Next.js app
│   ├── mobile/           # React Native app
│   └── extension/        # Browser extension
├── packages/
│   ├── ui/               # Shared UI components
│   │   ├── web/          # Web-specific UI
│   │   ├── mobile/       # Mobile-specific UI
│   │   └── shared/       # Cross-platform UI
│   ├── api/              # API routes/handlers
│   ├── db/               # Database schema/queries
│   ├── auth/             # Authentication
│   ├── i18n/             # Internationalization
│   └── shared/           # Shared utilities
└── tooling/
    ├── eslint/           # ESLint config
    ├── typescript/       # TypeScript config
    └── prettier/         # Prettier config
```

**Package Naming**:

| Location | Name Pattern | Import |
|----------|--------------|--------|
| `packages/ui/web` | `@workspace/ui-web` | `@workspace/ui-web/button` |
| `packages/db` | `@workspace/db` | `@workspace/db/schema` |
| `tooling/eslint` | `@workspace/eslint-config` | `@workspace/eslint-config` |

**turbo.json Configuration**:

```json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": [".next/**", "dist/**"]
    },
    "dev": {
      "cache": false,
      "persistent": true
    },
    "lint": {
      "dependsOn": ["^build"]
    },
    "typecheck": {
      "dependsOn": ["^build"]
    }
  }
}
```

<!-- AI-CONTEXT-END -->

## Detailed Patterns

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
// Usage in apps/web
import { Button } from "@workspace/ui-web/button";
import { cn } from "@workspace/ui-web";
import "@workspace/ui-web/globals.css";
```

### Workspace Dependencies

```json
// apps/web/package.json
{
  "dependencies": {
    "@workspace/ui-web": "workspace:*",
    "@workspace/api": "workspace:*",
    "@workspace/db": "workspace:*"
  }
}
```

### Filtering Commands

```bash
# Single package
pnpm --filter web dev

# Package and dependencies
pnpm --filter web... build

# Package and dependents
pnpm --filter ...web build

# Multiple packages
pnpm --filter web --filter mobile dev

# By directory
pnpm --filter "./packages/*" build

# Exclude package
pnpm --filter "!web" build
```

### Environment Variables

```bash
# "with-env" is a custom script using dotenv-cli to load .env before turbo
# Equivalent to: pnpm dotenv -- turbo build
pnpm with-env turbo build

# In package.json
{
  "scripts": {
    "build": "pnpm with-env turbo build",
    "dev": "pnpm with-env turbo dev"
  }
}
```

### Shared TypeScript Config

```json
// tooling/typescript/base.json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "compilerOptions": {
    "strict": true,
    "moduleResolution": "bundler",
    "module": "ESNext",
    "target": "ES2022",
    "lib": ["ES2022"],
    "skipLibCheck": true,
    "esModuleInterop": true
  }
}

// packages/api/tsconfig.json
{
  "extends": "@workspace/tsconfig/base.json",
  "compilerOptions": {
    "outDir": "dist"
  },
  "include": ["src"]
}
```

### Shared ESLint Config

```js
// tooling/eslint/base.js
module.exports = {
  extends: ["eslint:recommended", "prettier"],
  rules: {
    // Shared rules
  },
};

// apps/web/eslint.config.js
import baseConfig from "@workspace/eslint-config/base";

export default [
  ...baseConfig,
  // App-specific overrides
];
```

### Database Package Pattern

```tsx
// packages/db/src/index.ts
export * from "./schema";
export type { InferSelectModel, InferInsertModel } from "drizzle-orm";

// packages/db/src/server.ts
export { db } from "./client";

// packages/db/src/schema/index.ts
export * from "./users";
export * from "./posts";
export * from "./auth";
```

### Running Database Commands

```bash
# Generate migrations
pnpm --filter @workspace/db db:generate

# Apply migrations
pnpm --filter @workspace/db db:migrate

# Open studio
pnpm --filter @workspace/db db:studio

# Or use turbo
turbo db:generate --filter=@workspace/db
```

## Common Mistakes

1. **Circular dependencies**
   - Package A imports B, B imports A
   - Extract shared code to third package

2. **Missing `^` in dependsOn**
   - `"dependsOn": ["build"]` - same package
   - `"dependsOn": ["^build"]` - dependencies first

3. **Cache not invalidating**
   - Check `outputs` in turbo.json
   - Add env vars to `globalEnv` if needed

4. **Wrong workspace protocol**
   - Use `"workspace:*"` not `"*"`
   - Ensures local package is used

5. **TypeScript path issues**
   - Use `moduleResolution: "bundler"`
   - Match exports in package.json

## Related

- `tools/api/drizzle.md` - Database in monorepo
- `tools/ui/nextjs-layouts.md` - App structure
- Context7 MCP for Turborepo documentation
