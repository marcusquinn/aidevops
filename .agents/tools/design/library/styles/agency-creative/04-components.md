<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Agency Creative — Component Stylings

## Buttons

**Primary Button (Gradient)**

```css
background: linear-gradient(135deg, #7c3aed, #ec4899)
color: #ffffff
font: 15px/1 Inter, 600
padding: 14px 32px
border: none
border-radius: 999px
box-shadow: 0 4px 16px rgba(124, 58, 237, 0.3)
transition: all 300ms cubic-bezier(0.34, 1.56, 0.64, 1)

:hover    → transform: translateY(-2px); box-shadow: 0 8px 32px rgba(124, 58, 237, 0.4)
:active   → transform: translateY(0); box-shadow: 0 2px 8px rgba(124, 58, 237, 0.3)
:focus    → outline: 2px solid #a78bfa; outline-offset: 3px
:disabled → opacity: 0.5; cursor: not-allowed; transform: none
```

**Secondary Button**

```css
background: transparent
color: #f8fafc (dark) / #0f0f0f (light)
font: 15px/1 Inter, 600
padding: 14px 32px
border: 2px solid #7c3aed
border-radius: 999px

:hover    → background: rgba(124, 58, 237, 0.1); transform: translateY(-1px)
:active   → background: rgba(124, 58, 237, 0.15)
:focus    → outline: 2px solid #a78bfa; outline-offset: 3px
:disabled → opacity: 0.5; cursor: not-allowed
```

**Ghost Button**

```css
background: transparent
color: #a1a1aa (dark) / #52525b (light)
font: 15px/1 Inter, 500
padding: 14px 32px
border: none
border-radius: 999px

:hover    → color: #f8fafc; background: rgba(255,255,255,0.05)
:active   → background: rgba(255,255,255,0.08)
```

## Inputs

```css
background: #18181b (dark) / #ffffff (light)
color: #f8fafc (dark) / #0f0f0f (light)
font: 15px Inter
padding: 14px 18px
border: 1px solid #27272a (dark) / #e4e4e7 (light)
border-radius: 12px

::placeholder → color: #52525b
:hover        → border-color: #3f3f46
:focus        → border-color: #7c3aed; box-shadow: 0 0 0 4px rgba(124, 58, 237, 0.15)
:invalid      → border-color: #f87171
```

## Links

```css
color: #a78bfa (dark) / #7c3aed (light)
text-decoration: none
font-weight: 500
transition: color 200ms ease

:hover  → color: #c4b5fd; text-decoration: underline
:active → color: #7c3aed
```

## Cards

```css
background: #18181b (dark) / #ffffff (light)
border: 1px solid #27272a (dark) / #e4e4e7 (light)
border-radius: 16px
padding: 32px
transition: transform 300ms cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 300ms ease

:hover → transform: translateY(-4px); box-shadow: 0 12px 40px rgba(0,0,0,0.3) (dark) / 0 12px 40px rgba(0,0,0,0.08) (light)
```

## Navigation

```css
Background: transparent (scrolled: #0f0f0f/95 with backdrop-blur: 16px)
Height: 72px
Logo: bold display wordmark or logomark, left-aligned
Nav items: 15px Inter, 500, #a1a1aa
Active item: #f8fafc with gradient underline
CTA in nav: pill button with gradient
```
