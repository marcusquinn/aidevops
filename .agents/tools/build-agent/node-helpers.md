<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Node.js Helper Script Patterns

Reference for common patterns used in Node.js-based helper scripts.

## NODE_PATH for globally installed npm packages

When a helper script uses `node -e` with globally installed npm packages, Node.js
does not automatically search the global npm prefix for inline evaluation. Set
`NODE_PATH` near the top of the script so CommonJS `require()` can resolve global
modules:

```bash
# Set NODE_PATH so Node.js can find globally installed modules
export NODE_PATH="$(npm root -g):$NODE_PATH"
```

This is required because `node -e` evaluates code in CommonJS mode, and without
`NODE_PATH` pointing at the global prefix, `require('some-global-package')` will
fail with `MODULE_NOT_FOUND` even when the package is installed globally.

> **Note:** `NODE_PATH` only affects CommonJS `require()`. ESM `import` specifiers
> are not resolved via `NODE_PATH` — use explicit paths or local installs for ESM.

## Prefer bun for performance

Where scripts reference `npm` or `npx`, consider `bun` for faster execution:

- `bun` is significantly faster for package operations
- Compatible with most npm packages
- Prefer `bunx` over `npx` for one-off executions
