---
name: fonts
mode: subagent
description: Loading Google Fonts and local fonts in Remotion
metadata:
  tags: fonts, google-fonts, typography, text
---

# Using fonts in Remotion

## Google Fonts (`@remotion/google-fonts`)

Type-safe, auto-blocks rendering until ready. Install:

```bash
npx remotion add @remotion/google-fonts  # npm
bunx remotion add @remotion/google-fonts  # bun
yarn remotion add @remotion/google-fonts  # yarn
pnpm exec remotion add @remotion/google-fonts  # pnpm
```

Basic usage — import per-font, destructure `fontFamily`:

```tsx
import { loadFont } from "@remotion/google-fonts/Roboto";

const { fontFamily } = loadFont("normal", {
  weights: ["400", "700"],
  subsets: ["latin"],  // specify weights/subsets to reduce file size
});

export const Title: React.FC<{ text: string }> = ({ text }) => (
  <h1 style={{ fontFamily, fontSize: 80, fontWeight: "bold" }}>{text}</h1>
);
```

Wait for font ready (e.g., before measuring text):

```tsx
const { fontFamily, waitUntilDone } = loadFont();
await waitUntilDone();
```

## Local fonts (`@remotion/fonts`)

Install:

```bash
npx remotion add @remotion/fonts  # npm
bunx remotion add @remotion/fonts  # bun
yarn remotion add @remotion/fonts  # yarn
pnpm exec remotion add @remotion/fonts  # pnpm
```

Place font files in `public/`. Load at module level (before component render):

```tsx
import { loadFont } from "@remotion/fonts";
import { staticFile } from "remotion";

// Single weight
await loadFont({
  family: "MyFont",
  url: staticFile("MyFont-Regular.woff2"),
});

// Multiple weights — same family name, parallel load
await Promise.all([
  loadFont({ family: "Inter", url: staticFile("Inter-Regular.woff2"), weight: "400" }),
  loadFont({ family: "Inter", url: staticFile("Inter-Bold.woff2"), weight: "700" }),
]);

export const MyComposition = () => (
  <div style={{ fontFamily: "MyFont" }}>Hello World</div>
);
```

`loadFont` options:

```tsx
loadFont({
  family: "MyFont",          // Required: CSS font-family name
  url: staticFile("f.woff2"), // Required: font file URL
  format: "woff2",           // Optional: auto-detected from extension
  weight: "400",             // Optional: font weight
  style: "normal",           // Optional: normal | italic
  display: "block",          // Optional: font-display behavior
});
```
