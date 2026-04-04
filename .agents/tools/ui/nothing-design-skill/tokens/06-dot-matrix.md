<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Nothing Design System — Dot-Matrix Motif

**When to use:** Hero typography (Doto), decorative grid backgrounds, dot-grid data viz, loading indicators, empty state illustrations.

```css
.dot-grid {
  background-image: radial-gradient(circle, var(--border-visible) 1px, transparent 1px);
  background-size: 16px 16px;
}
.dot-grid-subtle {
  background-image: radial-gradient(circle, var(--border) 0.5px, transparent 0.5px);
  background-size: 12px 12px;
}
```

Dots 1-2px, uniform 12-16px grid. Opacity 0.1-0.2 for backgrounds, full for data. Never as container border or button style.
