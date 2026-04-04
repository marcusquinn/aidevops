<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agency Techie — Component Stylings

## Buttons

**Primary Button**

```css
background: #22d3ee
color: #0d1117
font: 14px/1 Inter, 500
padding: 10px 20px
border: none
border-radius: 4px
transition: all 150ms ease-out

:hover    → background: #06b6d4; box-shadow: 0 0 12px rgba(34, 211, 238, 0.2)
:active   → background: #0891b2; transform: translateY(1px)
:focus    → outline: 2px solid #22d3ee; outline-offset: 2px
:disabled → background: #164e63; color: #475569; cursor: not-allowed
```

**Secondary Button**

```css
background: transparent
color: #e2e8f0
font: 14px/1 Inter, 500
padding: 10px 20px
border: 1px solid #1e293b
border-radius: 4px

:hover    → border-color: #334155; background: rgba(255,255,255,0.03)
:active   → background: rgba(255,255,255,0.06)
:focus    → outline: 2px solid #22d3ee; outline-offset: 2px
:disabled → color: #475569; border-color: #162032; cursor: not-allowed
```

**Ghost Button**

```css
background: transparent
color: #94a3b8
font: 14px/1 Inter, 500
padding: 10px 20px
border: none
border-radius: 4px

:hover    → color: #e2e8f0; background: rgba(34, 211, 238, 0.08)
:active   → background: rgba(34, 211, 238, 0.12)
:focus    → outline: 2px solid #22d3ee; outline-offset: 2px
```

## Inputs

```css
background: #161b22
color: #e2e8f0
font: 14px JetBrains Mono (for code inputs) or Inter (for text inputs)
padding: 10px 14px
border: 1px solid #1e293b
border-radius: 4px

::placeholder → color: #475569
:hover        → border-color: #334155
:focus        → border-color: #22d3ee; box-shadow: 0 0 0 3px rgba(34, 211, 238, 0.1)
:invalid      → border-color: #f87171
:disabled     → background: #0d1117; color: #475569
```

## Links

```css
color: #22d3ee
text-decoration: none
transition: color 150ms ease-out

:hover  → color: #67e8f9; text-decoration: underline
:active → color: #06b6d4
```

## Cards

```css
background: #161b22
border: 1px solid #1e293b
border-radius: 6px
padding: 20px
transition: border-color 150ms ease-out

:hover → border-color: #334155
```

## Navigation

```css
Background: #0d1117
Border bottom: 1px solid #1e293b
Height: 56px
Logo: left-aligned, 24px mono wordmark
Nav items: 14px Inter, 500, #94a3b8
Active item: #e2e8f0, border-bottom: 2px solid #22d3ee
```
