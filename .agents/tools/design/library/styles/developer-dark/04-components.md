<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Developer Dark — Component Stylings

## Buttons

```css
/* Primary (Green) */
background: #4ade80
color: #111827
border: none
border-radius: 4px
padding: 8px 16px
font: JetBrains Mono 13px/1 600; text-transform: uppercase; letter-spacing: 0.5px

:hover    → background: #22c55e
:focus    → outline: 2px solid #4ade80; outline-offset: 2px
:active   → background: #16a34a
:disabled → opacity: 0.4; cursor: not-allowed

/* Secondary (Ghost) */
background: transparent
color: #f9fafb
border: 1px solid #374151
border-radius: 4px
padding: 8px 16px

:hover    → background: #1f2937; border-color: #4b5563
:focus    → outline: 2px solid #4ade80; outline-offset: 2px

/* Danger */
background: #ef4444
color: #ffffff
border: none
border-radius: 4px

:hover    → background: #dc2626
```

## Inputs

```css
/* Text Input */
background: #0d1117
color: #f9fafb
border: 1px solid #374151
border-radius: 4px
padding: 8px 12px
font: JetBrains Mono 14px/1 400
placeholder-color: #6b7280

:focus → border-color: #4ade80; box-shadow: 0 0 0 2px rgba(74, 222, 128, 0.2)
:error → border-color: #ef4444; box-shadow: 0 0 0 2px rgba(239, 68, 68, 0.2)
```

## Links

```css
color: #3b82f6; text-decoration: underline  /* body text — accessibility requirement; see 07-dos-donts.md */
:hover  → color: #60a5fa
:active → color: #2563eb
/* code links */ color: #4ade80; :hover → color: #22c55e
```

## Cards & Containers

```css
background: #1f2937
border: 1px solid #374151
border-radius: 4px
padding: 16px
box-shadow: none  /* border-driven depth */

:hover → border-color: #4b5563
```

## Navigation

```css
/* Top bar */
position: sticky; top: 0
background: #111827
border-bottom: 1px solid #1f2937

/* Nav links */ font: JetBrains Mono 13px/1 500; color: #9ca3af
:active → color: #4ade80
:hover  → color: #f9fafb

/* Logo/brand */ font: JetBrains Mono 15px/1 700; color: #f9fafb
```
