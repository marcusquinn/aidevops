<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Startup Minimal — Component Stylings

## Buttons

**Primary Button**

```css
background: #2563eb
color: #ffffff
font: 13px/1 Inter, 500
padding: 8px 16px
border: none
border-radius: 6px
transition: background 150ms ease

:hover    → background: #1d4ed8
:active   → background: #1e40af
:focus    → outline: 2px solid #2563eb; outline-offset: 1px
:disabled → background: #93c5fd; cursor: not-allowed
```

**Secondary Button**

```css
background: #ffffff
color: #18181b
font: 13px/1 Inter, 500
padding: 8px 16px
border: 1px solid #e5e7eb
border-radius: 6px

:hover    → background: #fafafa; border-color: #d4d4d8
:active   → background: #f4f4f5
:focus    → outline: 2px solid #2563eb; outline-offset: 1px
:disabled → color: #a1a1aa; background: #fafafa
```

**Ghost Button**

```css
background: transparent
color: #71717a
font: 13px/1 Inter, 500
padding: 8px 16px
border: none
border-radius: 6px

:hover    → color: #18181b; background: rgba(0, 0, 0, 0.04)
:active   → background: rgba(0, 0, 0, 0.06)
```

**Danger Button**

```css
background: #dc2626
color: #ffffff
font: 13px/1 Inter, 500
padding: 8px 16px
border: none
border-radius: 6px

:hover    → background: #b91c1c
:active   → background: #991b1b
```

## Inputs

```css
background: #ffffff
color: #18181b
font: 14px Inter
padding: 8px 12px
border: 1px solid #e5e7eb
border-radius: 6px
box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04)
transition: border-color 150ms ease

::placeholder → color: #a1a1aa
:hover        → border-color: #d4d4d8
:focus        → border-color: #2563eb; box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.1); outline: none
:invalid      → border-color: #dc2626
:disabled     → background: #f4f4f5; color: #a1a1aa
```

## Links

```css
color: #2563eb
text-decoration: none
transition: color 150ms ease

:hover  → color: #1d4ed8; text-decoration: underline
:active → color: #1e40af
```

## Cards

```css
background: #ffffff
border: 1px solid #e5e7eb
border-radius: 8px
padding: 24px

(No shadow at rest. No hover animation by default — add only if the card is interactive/clickable.)

Interactive variant:
:hover → border-color: #d4d4d8; box-shadow: 0 2px 8px rgba(0, 0, 0, 0.06)
```

## Navigation

```css
Background: #ffffff
Border bottom: 1px solid #e5e7eb
Height: 56px
Logo: 18px Inter 600 #18181b (text wordmark) or small logomark
Nav items: 14px Inter, 500, #71717a
Active item: #18181b, font-weight: 500
Hover item: #18181b
CTA in nav: small primary button
```
