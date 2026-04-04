<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mobile Form Optimization

1. **Minimize fields** — target <5 (each feels 3x harder on mobile)
2. **Single-column layout** — always
3. **48px min height**, 16px+ font (prevents iOS Safari auto-zoom)
4. **Correct input types + autofill** — triggers appropriate keyboard and one-tap fill:

```html
<input type="email" autocomplete="email">   <!-- @ and .com keys -->
<input type="tel" autocomplete="tel">       <!-- Number pad -->
<input type="url">                          <!-- .com and / keys -->
<input type="number">                       <!-- Number pad -->
<input type="date">                         <!-- Native date picker -->
<input type="text" autocomplete="name">
<input type="text" autocomplete="street-address">
```

5. **Labels above fields** (not placeholder-only)
6. **Inline validation** — errors on blur, not on submit
7. **Input masks** for formatted fields (Cleave.js, react-input-mask)

```css
input, select, textarea { min-height: 48px; padding: 12px; font-size: 16px; /* Prevents iOS auto-zoom */ }
```
