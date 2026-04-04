---
name: fonts
mode: subagent
description: Loading Google Fonts and local fonts in Remotion
metadata:
  tags: fonts, google-fonts, typography, text
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Using fonts in Remotion

## Google Fonts (`@remotion/google-fonts`)

Use for fonts available on Google Fonts. Type-safe; blocks rendering until ready.

```bash
npx remotion add @remotion/google-fonts
bunx remotion add @remotion/google-fonts
yarn remotion add @remotion/google-fonts
pnpm exec remotion add @remotion/google-fonts
```

```tsx
import { loadFont } from "@remotion/google-fonts/Roboto";

const { fontFamily, waitUntilDone } = loadFont("normal", {
  weights: ["400", "700"],
  subsets: ["latin"],
});

await waitUntilDone(); // Required before measuring text or DOM layout

export const Title: React.FC<{ text: string }> = ({ text }) => (
  <h1 style={{ fontFamily, fontSize: 80, fontWeight: "bold" }}>{text}</h1>
);
```

*Tip: Specify only required weights/subsets to minimize bundle size.*

## Local Fonts (`@remotion/fonts`)

Use for custom font files. Place in `public/` and load at module scope (not during render).

```bash
npx remotion add @remotion/fonts
bunx remotion add @remotion/fonts
yarn remotion add @remotion/fonts
pnpm exec remotion add @remotion/fonts
```

```tsx
import { loadFont } from "@remotion/fonts";
import { staticFile } from "remotion";

// Single font
await loadFont({ family: "MyFont", url: staticFile("MyFont-Regular.woff2") });

// Multiple weights
await Promise.all([
  loadFont({ family: "Inter", url: staticFile("Inter-Regular.woff2"), weight: "400" }),
  loadFont({ family: "Inter", url: staticFile("Inter-Bold.woff2"), weight: "700" }),
]);
```

### `loadFont()` Options

```tsx
loadFont({
  family: "MyFont",           // Required: CSS font-family name
  url: staticFile("f.woff2"), // Required: Font file URL
  format: "woff2",            // Optional: Inferred from extension
  weight: "400",              // Optional
  style: "normal",            // Optional: normal | italic
  display: "block",           // Optional: font-display value
});
```
