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

# Frontend Debugging Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Golden Rule**: Always verify frontend fixes with browser screenshot, never trust curl alone
- **Hydration errors**: Usually mean server/client mismatch or invalid component types
- **Monorepo gotchas**: Webpack loaders (SVGR, etc.) don't cross package boundaries
- **Browser tool**: `dev-browser` agent for visual verification

**When to read this guide**:
- Debugging React/Next.js errors
- "Something went wrong" or blank page issues
- Hydration mismatch errors
- Working in monorepo `packages/` directories
- After curl returns 200 but user reports errors

<!-- AI-CONTEXT-END -->

## The Browser Verification Rule

**CRITICAL**: HTTP status codes and HTML responses do NOT verify frontend functionality.

### Why curl Lies

```bash
# This returns 200 OK even when React crashes client-side:
curl -s https://myapp.local -o /dev/null -w "%{http_code}"
# Output: 200

# The HTML contains the error boundary, not the actual app:
curl -s https://myapp.local | grep -o "Something went wrong"
# Output: Something went wrong
```

**The server returns 200 because**:
- Next.js SSR renders the error boundary successfully
- The HTTP response is valid HTML
- The crash happens during client-side hydration

### Always Use Browser Verification

After ANY frontend fix, verify with actual browser rendering:

```bash
# Start dev-browser if not running
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start

# Take screenshot to verify
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("verify");

await page.goto("https://myapp.local");
await waitForPageLoad(page);

// Check for error indicators
const hasError = await page.evaluate(() => {
  const body = document.body.innerText;
  return body.includes("Something went wrong") || 
         body.includes("Error:") ||
         body.includes("Unhandled Runtime Error");
});

if (hasError) {
  console.log("ERROR DETECTED - taking screenshot");
  await page.screenshot({ path: "tmp/error-state.png", fullPage: true });
} else {
  console.log("Page loaded successfully");
  await page.screenshot({ path: "tmp/success-state.png" });
}

console.log({ url: page.url(), title: await page.title(), hasError });
await client.disconnect();
EOF
```

### When to Trigger Browser Verification

Automatically suggest browser verification when:

1. **After fixing any frontend error** - especially hydration/render errors
2. **User reports "not working"** but curl returns 200
3. **Modifying shared UI packages** in monorepos
4. **Changing component imports** or export patterns
5. **After clearing caches** (.next, node_modules)

## React Hydration Errors

### Understanding Hydration

Hydration = React attaching event handlers to server-rendered HTML. Fails when:
- Server HTML doesn't match client render
- Component returns invalid type (object instead of function)
- Browser APIs used during SSR

### Common Error Patterns

| Error Message | Likely Cause | Solution |
|---------------|--------------|----------|
| `Element type is invalid: expected string... got: object` | Import returning wrong type | Check import path, verify export is React component |
| `Hydration failed because initial UI does not match` | Server/client mismatch | Check for browser-only code, use `useEffect` for client-only |
| `Text content does not match` | Dynamic content in SSR | Use `suppressHydrationWarning` or move to client component |
| `Cannot read properties of undefined` | Missing data during SSR | Add null checks, use loading states |

### The "got: object" Pattern

This specific error almost always means an import is returning the wrong type:

```typescript
// BAD: SVGR import in shared package (returns object, not component)
import Logo from "./svg/logo.svg";  // Returns { src: "...", height: ..., width: ... }

// GOOD: Inline React component
export const Logo = (props: SVGProps<SVGSVGElement>) => (
  <svg viewBox="0 0 100 100" {...props}>
    <path d="..." />
  </svg>
);
```

**Debugging steps**:
1. Find the component mentioned in error (e.g., `Header`)
2. Check all imports in that component
3. Look for non-standard imports (SVG, JSON, CSS modules)
4. Verify each import returns expected type

## Monorepo Package Boundaries

### The Webpack Loader Problem

Webpack loaders (SVGR, CSS modules, etc.) only process files within the app's webpack pipeline.

```text
apps/web/                    # Webpack processes this
  src/
    components/
      Logo.tsx               # Can use: import Logo from "./logo.svg"
      
packages/ui/                 # Transpiled by Next.js, NOT webpack
  src/
    icons.tsx                # CANNOT use: import Logo from "./logo.svg"
                             # SVG import returns raw object, not component
```

### What Works vs What Doesn't

| Pattern | In App (`apps/web/`) | In Package (`packages/ui/`) |
|---------|---------------------|----------------------------|
| `import X from "./file.svg"` (SVGR) | Works | **Broken** - returns object |
| `import styles from "./file.module.css"` | Works | **Broken** - returns object |
| `import data from "./file.json"` | Works | Works (JSON is universal) |
| Inline React components | Works | Works |
| `@svgr/webpack` configured | Works | **Not applied** |

### Solutions for Shared Packages

**Option 1: Inline SVG Components (Recommended)**

```typescript
// packages/ui/shared/src/assets/icons.tsx
import type { SVGProps } from "react";

export const Logo = (props: SVGProps<SVGSVGElement>) => (
  <svg viewBox="0 0 100 100" fill="currentColor" {...props}>
    <path d="M10 10 L90 10 L90 90 L10 90 Z" />
  </svg>
);

export const Icon = (props: SVGProps<SVGSVGElement>) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" {...props}>
    <path strokeLinecap="round" d="M12 4v16m-8-8h16" />
  </svg>
);
```

**Option 2: Build-time SVG transformation**

Configure the shared package to transform SVGs during its own build:

```json
// packages/ui/package.json
{
  "scripts": {
    "build": "tsup --loader '.svg=dataurl'"
  }
}
```

**Option 3: Re-export from app**

Keep SVG imports in the app, re-export to packages:

```typescript
// apps/web/src/assets/icons.ts
export { default as Logo } from "./svg/logo.svg";

// packages/ui uses the app's exports (requires careful dependency management)
```

### Detection Checklist

When working in `packages/` directories, check for:

- [ ] SVG imports (`import X from "*.svg"`)
- [ ] CSS module imports (`import styles from "*.module.css"`)
- [ ] Any webpack-loader-dependent imports
- [ ] Assets that work in `apps/` but might not in `packages/`

## Debugging Workflow

### Step 1: Reproduce with Browser

```bash
# Don't trust curl - use browser
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start
# Navigate to URL, take screenshot
```

### Step 2: Check Console Errors

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";

const client = await connect("http://localhost:9222");
const page = await client.page("debug");

// Capture console errors
const errors: string[] = [];
page.on('console', msg => {
  if (msg.type() === 'error') errors.push(msg.text());
});
page.on('pageerror', err => errors.push(err.message));

await page.goto("https://myapp.local");
await waitForPageLoad(page);

console.log("Console errors:", errors);
await client.disconnect();
EOF
```

### Step 3: Identify Component

From error message, find the failing component:
- `Check the render method of 'Header'` → Look at Header component
- Trace imports back to source

### Step 4: Verify Import Types

```typescript
// Add temporary debug logging
console.log("Logo type:", typeof Logo, Logo);
// Object = broken import
// Function = valid React component
```

### Step 5: Fix and Verify with Browser

After fix, ALWAYS verify with browser screenshot, not curl.

## Related Resources

- **Browser automation**: `tools/browser/dev-browser.md`
- **React patterns**: `tools/ui/shadcn.md`
- **Build debugging**: `workflows/bug-fixing.md`
