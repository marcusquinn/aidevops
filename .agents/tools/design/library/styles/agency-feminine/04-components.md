<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agency Feminine — Component Stylings

## Buttons

```css
/* Shared base */
font: 14px/1 Lato, 500; padding: 14px 32px; border-radius: 999px; letter-spacing: 0.04em

/* Primary */
background: #d4a5a5; color: #ffffff; border: none; transition: all 400ms ease-in-out
:hover    → background: #c79393; box-shadow: 0 4px 16px rgba(212, 165, 165, 0.25)
:active   → background: #b88282; transform: scale(0.98)
:focus    → outline: 2px solid #d4a5a5; outline-offset: 3px
:disabled → background: #e8cece; color: #b0a59c; cursor: not-allowed

/* Secondary */
background: transparent; color: #3d3530; border: 1.5px solid #d4a5a5
:hover    → background: #f5ebe7; border-color: #c79393
:active   → background: #f0e6d8
:focus    → outline: 2px solid #d4a5a5; outline-offset: 3px
:disabled → color: #b0a59c; border-color: #e8ddd0

/* Ghost */
background: transparent; color: #7a6e65; font-weight: 400; border: none
:hover  → color: #3d3530; background: rgba(212, 165, 165, 0.08)
:active → background: rgba(212, 165, 165, 0.12)
```

## Inputs

```css
background: #ffffff; color: #3d3530; font: 15px Lato, 300
padding: 14px 18px; border: 1px solid #e8ddd0; border-radius: 12px; transition: all 300ms ease
::placeholder → color: #b0a59c
:hover        → border-color: #d4ccc3
:focus        → border-color: #d4a5a5; box-shadow: 0 0 0 4px rgba(212, 165, 165, 0.12)
:invalid      → border-color: #c97070
:disabled     → background: #f8f0e5; color: #b0a59c
```

## Links

```css
color: #b07878; text-decoration: none; font-weight: 400; transition: color 300ms ease
:hover  → color: #966060; text-decoration: underline; text-underline-offset: 4px
:active → color: #7a4a4a
```

## Cards

```css
background: #ffffff; border: 1px solid #e8ddd0; border-radius: 16px
padding: 32px; box-shadow: 0 2px 12px rgba(61, 53, 48, 0.06); transition: all 400ms ease-in-out
:hover → box-shadow: 0 4px 24px rgba(61, 53, 48, 0.08); transform: translateY(-2px)
```

## Navigation

```css
background: #fdf6ee (or transparent + backdrop-filter: blur(12px) on scroll)
height: 72px; border-bottom: 1px solid #e8ddd0
logo: Cormorant serif wordmark, 24px, #3d3530
nav-items: 14px Lato, 400, #7a6e65; active: #3d3530, font-weight: 500; hover: #3d3530
cta: small pill button, background: #d4a5a5
```
