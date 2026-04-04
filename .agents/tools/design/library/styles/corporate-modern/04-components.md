# Design System: Corporate Modern — Component Stylings

## Buttons

Shared base: `padding: 10px 24px`, `border-radius: 8px`, `font-size: 15px`, `font-weight: 600`

**Primary:**

```css
background: #0891b2
color: #FFFFFF
border: none
line-height: 1.4
cursor: pointer
transition: all 150ms ease-out

:hover    → background: #0e7490; box-shadow: 0 2px 8px rgba(8, 145, 178, 0.25)
:active   → background: #155e75; transform: translateY(0.5px)
:focus    → outline: 2px solid #0891b2; outline-offset: 2px
:disabled → background: #E2E8F0; color: #94a3b8; cursor: not-allowed
```

**Secondary:**

```css
background: #FFFFFF
color: #1a1a2e
border: 1px solid #E2E8F0

:hover    → border-color: #CBD5E1; background: #F8FAFC
:active   → background: #E2E8F0
:disabled → color: #94a3b8; border-color: #E2E8F0
```

**Ghost:**

```css
background: transparent
color: #0891b2
border: none

:hover  → background: #ecfeff
:active → background: #cffafe
```

## Inputs

```css
background: #FFFFFF
border: 1px solid #E2E8F0
border-radius: 8px
padding: 10px 14px
font-size: 15px
color: #1a1a2e
transition: border-color 150ms ease-out, box-shadow 150ms ease-out

:hover       → border-color: #CBD5E1
:focus       → border-color: #0891b2; box-shadow: 0 0 0 3px rgba(8, 145, 178, 0.12)
:error       → border-color: #dc2626; box-shadow: 0 0 0 3px rgba(220, 38, 38, 0.08)
::placeholder → color: #94a3b8
:disabled    → background: #F8FAFC; color: #94a3b8; border-color: #E2E8F0
```

**Labels:** 14px, weight 500, colour `#1a1a2e`, margin-bottom 6px.
**Helper text:** 13px, weight 400, colour `#64748b`, margin-top 4px.

## Links

```css
color: #0891b2
text-decoration: none
font-weight: 500
transition: color 150ms ease-out

:hover  → color: #0e7490; text-decoration: underline; text-underline-offset: 3px
:active → color: #155e75
```

## Cards

```css
background: #FFFFFF
border: 1px solid #E2E8F0
border-radius: 12px
padding: 24px
transition: box-shadow 150ms ease-out, border-color 150ms ease-out

Interactive cards:
:hover → border-color: #CBD5E1; box-shadow: 0 4px 12px rgba(26, 26, 46, 0.06)
```

## Navigation

```css
Top bar:
  background: #FFFFFF
  border-bottom: 1px solid #E2E8F0
  height: 64px
  padding: 0 24px

Nav links:
  color: #64748b
  font-size: 14px
  font-weight: 500
  :hover  → color: #1a1a2e
  :active → color: #0891b2; font-weight: 600

Mobile nav:
  Slide-in from left, 280px wide
  background: #FFFFFF
  box-shadow: 4px 0 16px rgba(26, 26, 46, 0.08)
```
