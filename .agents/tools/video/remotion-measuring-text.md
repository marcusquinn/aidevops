---
name: measuring-text
mode: subagent
description: Measuring text dimensions, fitting text to containers, and checking overflow
metadata:
  tags: measure, text, layout, dimensions, fitText, fillTextBox
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Measuring text in Remotion

## Prerequisites

Install `@remotion/layout-utils`:

```bash
npx remotion add @remotion/layout-utils # npm
bunx remotion add @remotion/layout-utils # bun
yarn remotion add @remotion/layout-utils # yarn
pnpm exec remotion add @remotion/layout-utils # pnpm
```

## measureText() — get text dimensions

```tsx
import { measureText } from "@remotion/layout-utils";

const { width, height } = measureText({
  text: "Hello World",
  fontFamily: "Arial",
  fontSize: 32,
  fontWeight: "bold",
});
```

Results are cached — duplicate calls return instantly.

## fitText() — optimal font size for a container

```tsx
import { fitText } from "@remotion/layout-utils";

const { fontSize } = fitText({
  text: "Hello World",
  withinWidth: 600,
  fontFamily: "Inter",
  fontWeight: "bold",
});

return (
  <div
    style={{
      fontSize: Math.min(fontSize, 80), // Cap at 80px
      fontFamily: "Inter",
      fontWeight: "bold",
    }}
  >
    Hello World
  </div>
);
```

## fillTextBox() — detect overflow

```tsx
import { fillTextBox } from "@remotion/layout-utils";

const box = fillTextBox({ maxBoxWidth: 400, maxLines: 3 });

const words = ["Hello", "World", "This", "is", "a", "test"];
for (const word of words) {
  const { exceedsBox } = box.add({
    text: word + " ",
    fontFamily: "Arial",
    fontSize: 24,
  });
  if (exceedsBox) {
    // Text would overflow, handle accordingly
    break;
  }
}
```

## Best practices

**Load fonts before measuring.** Measurement is inaccurate if the font hasn't loaded yet.

```tsx
import { loadFont } from "@remotion/google-fonts/Inter";

const { fontFamily, waitUntilDone } = loadFont("normal", {
  weights: ["400"],
  subsets: ["latin"],
});

waitUntilDone().then(() => {
  const { width } = measureText({
    text: "Hello",
    fontFamily,
    fontSize: 32,
  });
})
```

**Use `validateFontIsLoaded` to catch missing fonts early:**

```tsx
measureText({
  text: "Hello",
  fontFamily: "MyCustomFont",
  fontSize: 32,
  validateFontIsLoaded: true, // Throws if font not loaded
});
```

**Match font properties between measurement and rendering:**

```tsx
const fontStyle = {
  fontFamily: "Inter",
  fontSize: 32,
  fontWeight: "bold" as const,
  letterSpacing: "0.5px",
};

const { width } = measureText({
  text: "Hello",
  ...fontStyle,
});

return <div style={fontStyle}>Hello</div>;
```

**Use `outline` instead of `border`** to prevent layout differences from padding/border:

```tsx
<div style={{ outline: "2px solid red" }}>Text</div>
```
