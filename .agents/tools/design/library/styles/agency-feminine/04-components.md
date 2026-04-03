# Agency Feminine — Component Stylings

## Buttons

**Primary Button**

```css
background: #d4a5a5
color: #ffffff
font: 14px/1 Lato, 500
padding: 14px 32px
border: none
border-radius: 999px
letter-spacing: 0.04em
transition: all 400ms ease-in-out

:hover    → background: #c79393; box-shadow: 0 4px 16px rgba(212, 165, 165, 0.25)
:active   → background: #b88282; transform: scale(0.98)
:focus    → outline: 2px solid #d4a5a5; outline-offset: 3px
:disabled → background: #e8cece; color: #b0a59c; cursor: not-allowed
```

**Secondary Button**

```css
background: transparent
color: #3d3530
font: 14px/1 Lato, 500
padding: 14px 32px
border: 1.5px solid #d4a5a5
border-radius: 999px
letter-spacing: 0.04em

:hover    → background: #f5ebe7; border-color: #c79393
:active   → background: #f0e6d8
:focus    → outline: 2px solid #d4a5a5; outline-offset: 3px
:disabled → color: #b0a59c; border-color: #e8ddd0
```

**Ghost Button**

```css
background: transparent
color: #7a6e65
font: 14px/1 Lato, 400
padding: 14px 32px
border: none
border-radius: 999px

:hover    → color: #3d3530; background: rgba(212, 165, 165, 0.08)
:active   → background: rgba(212, 165, 165, 0.12)
```

## Inputs

```css
background: #ffffff
color: #3d3530
font: 15px Lato, 300
padding: 14px 18px
border: 1px solid #e8ddd0
border-radius: 12px
transition: all 300ms ease

::placeholder → color: #b0a59c
:hover        → border-color: #d4ccc3
:focus        → border-color: #d4a5a5; box-shadow: 0 0 0 4px rgba(212, 165, 165, 0.12)
:invalid      → border-color: #c97070
:disabled     → background: #f8f0e5; color: #b0a59c
```

## Links

```css
color: #b07878
text-decoration: none
font-weight: 400
transition: color 300ms ease

:hover  → color: #966060; text-decoration: underline; text-underline-offset: 4px
:active → color: #7a4a4a
```

## Cards

```css
background: #ffffff
border: 1px solid #e8ddd0
border-radius: 16px
padding: 32px
box-shadow: 0 2px 12px rgba(61, 53, 48, 0.06)
transition: all 400ms ease-in-out

:hover → box-shadow: 0 4px 24px rgba(61, 53, 48, 0.08); transform: translateY(-2px)
```

## Navigation

```css
Background: #fdf6ee (or transparent with blur on scroll: backdrop-filter: blur(12px))
Height: 72px
Border bottom: 1px solid #e8ddd0
Logo: Cormorant serif wordmark, 24px, #3d3530
Nav items: 14px Lato, 400, #7a6e65
Active item: #3d3530, font-weight: 500
Hover item: #3d3530
CTA in nav: small pill button with #d4a5a5 background
```
