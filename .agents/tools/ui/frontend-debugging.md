---
description: Frontend debugging patterns - browser verification, hydration errors, monorepo gotchas
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Frontend Debugging Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Golden Rule**: Always verify frontend fixes with browser screenshot, never trust curl alone
- **Hydration errors**: Server/client mismatch or invalid component types
- **Monorepo gotchas**: Webpack loaders (SVGR, etc.) don't cross package boundaries
- **Browser tool**: `dev-browser` agent for visual verification

**When to use**: React/Next.js errors, blank pages, hydration mismatches, monorepo `packages/` work, curl returns 200 but user reports errors.

<!-- AI-CONTEXT-END -->

## Browser Verification (CRITICAL)

HTTP status codes do NOT verify frontend functionality. Next.js SSR renders error boundaries with 200 OK — the crash happens during client-side hydration. `curl` will show success while the app is broken.

After ANY frontend fix, verify with actual browser rendering:

```bash
# Start dev-browser if not running
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start

# Verify page + capture console errors
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("verify");

// Capture console errors
const errors: string[] = [];
page.on('console', msg => {
  if (msg.type() === 'error') errors.push(msg.text());
});
page.on('pageerror', err => errors.push(err.message));

await page.goto("https://myapp.local");
await waitForPageLoad(page);

const hasError = await page.evaluate(() => {
  const body = document.body.innerText;
  return body.includes("Something went wrong") ||
         body.includes("Error:") ||
         body.includes("Unhandled Runtime Error");
});

if (hasError) {
  console.log("ERROR DETECTED");
  await page.screenshot({ path: "tmp/error-state.png", fullPage: true });
} else {
  console.log("Page loaded successfully");
  await page.screenshot({ path: "tmp/success-state.png" });
}

console.log({ url: page.url(), title: await page.title(), hasError, errors });
await client.disconnect();
EOF
```

**Trigger browser verification when**: fixing frontend errors (especially hydration/render), user reports "not working" but curl returns 200, modifying shared UI packages, changing component imports/exports, after clearing caches (.next, node_modules).

## React Hydration Errors

Hydration = React attaching event handlers to server-rendered HTML. Fails when server HTML doesn't match client render, component returns invalid type, or browser APIs are used during SSR.

### Error Patterns

| Error Message | Cause | Fix |
|---------------|-------|-----|
| `Element type is invalid: expected string... got: object` | Import returning wrong type | Check import path, verify export is React component |
| `Hydration failed because initial UI does not match` | Server/client mismatch | Use `useEffect` for client-only code |
| `Text content does not match` | Dynamic content in SSR | `suppressHydrationWarning` or client component |
| `Cannot read properties of undefined` | Missing data during SSR | Add null checks, use loading states |

### The "got: object" Pattern

This error almost always means an import returns the wrong type — common with SVG imports in shared packages:

```typescript
// BAD: SVGR import in shared package (returns { src, height, width }, not component)
import Logo from "./svg/logo.svg";

// GOOD: Inline React component
import type { SVGProps } from "react";
export const Logo = (props: SVGProps<SVGSVGElement>) => (
  <svg viewBox="0 0 100 100" fill="currentColor" {...props}>
    <path d="M10 10 L90 10 L90 90 L10 90 Z" />
  </svg>
);
```

**Debug steps**: Find component in error → check all imports → look for non-standard imports (SVG, JSON, CSS modules) → verify each returns expected type. Add `console.log("X type:", typeof X, X)` — object = broken, function = valid component.

## Monorepo Package Boundaries

Webpack loaders (SVGR, CSS modules) only process files within the app's webpack pipeline. Shared packages under `packages/` are transpiled by Next.js but NOT processed by webpack loaders.

| Pattern | In `apps/web/` | In `packages/ui/` |
|---------|---------------|-------------------|
| `import X from "./file.svg"` (SVGR) | Works | **Broken** — returns object |
| `import styles from "./file.module.css"` | Works | **Broken** — returns object |
| `import data from "./file.json"` | Works | Works (JSON is universal) |
| Inline React components | Works | Works |
| `@svgr/webpack` configured | Works | **Not applied** |

### Solutions for Shared Packages

**Option 1: Inline SVG components (recommended)** — see the `Logo` example above. Works everywhere, no loader dependency.

**Option 2: Build-time SVG transformation** — configure the package's own build:

```json
// packages/ui/package.json
{
  "scripts": { "build": "tsup --loader '.svg=dataurl'" }
}
```

**Option 3: Re-export from app** — keep SVG imports in `apps/web/`, re-export to packages (requires careful dependency management).

**Detection checklist** for `packages/` directories: SVG imports (`*.svg`), CSS module imports (`*.module.css`), any webpack-loader-dependent imports, assets that work in `apps/` but might not in `packages/`.

## CSS Scroll Debugging

### "Scroll Trapped in Sidebar" Pattern

**Symptom**: Mouse wheel doesn't scroll the page when cursor is over a sidebar/panel.

**Root cause priority** (check in order):

1. **Global CSS** — `overscroll-behavior: none` on `*` or ancestors
2. **Overflow on non-scrollable content** — `overflow-auto` creates scroll container even when content fits
3. **Overlapping elements** — Rails, handles, or invisible buttons intercepting events
4. **JS event handlers** — only consider after ruling out CSS causes

**Anti-pattern**: Adding JS wheel event handlers before checking CSS. Always check `overscroll-behavior` and `overflow` in DevTools Computed styles first — on the element AND its children. Check for absolutely-positioned elements overlapping the area. Only investigate JS handlers if CSS is correct.

See `tools/ui/tailwind-css.md` for the Tailwind fix pattern.

## Related

- **Browser automation**: `tools/browser/dev-browser.md`
- **React patterns**: `tools/ui/shadcn.md`
- **Build debugging**: `workflows/bug-fixing.md`
