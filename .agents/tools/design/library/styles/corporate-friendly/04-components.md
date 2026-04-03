# Design System: Corporate Friendly — Components

## Buttons

**Primary Button:**

```css
background: #3b82f6
color: #FFFFFF
padding: 12px 28px
border: none
border-radius: 12px
font-size: 15px
font-weight: 600
cursor: pointer
transition: all 200ms ease-in-out

:hover    → background: #2563eb; box-shadow: 0 4px 12px rgba(59, 130, 246, 0.3)
:active   → background: #1d4ed8; transform: translateY(1px)
:focus    → outline: 2px solid #3b82f6; outline-offset: 2px
:disabled → background: #D1D5DB; color: #9ca3af; cursor: not-allowed
```

**Secondary Button:**

```css
background: #FFFFFF
color: #3b82f6
padding: 12px 28px
border: 1.5px solid #3b82f6
border-radius: 12px
font-size: 15px
font-weight: 600

:hover    → background: #eff6ff; border-color: #2563eb
:active   → background: #dbeafe
:disabled → border-color: #D1D5DB; color: #9ca3af
```

**Ghost Button:**

```css
background: transparent
color: #3b82f6
padding: 12px 28px
border: none
border-radius: 12px
font-size: 15px
font-weight: 600

:hover    → background: #eff6ff
:active   → background: #dbeafe
```

**Accent Button (secondary CTA):**

```css
background: #f97316
color: #FFFFFF
padding: 12px 28px
border-radius: 12px
font-size: 15px
font-weight: 600

:hover    → background: #ea580c; box-shadow: 0 4px 12px rgba(249, 115, 22, 0.3)
:active   → background: #c2410c; transform: translateY(1px)
```

## Inputs

```css
background: #FFFFFF
border: 1.5px solid #E5E7EB
border-radius: 12px
padding: 12px 16px
font-size: 16px
color: #111827
transition: all 200ms ease-in-out

:hover       → border-color: #D1D5DB
:focus       → border-color: #3b82f6; box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15)
:error       → border-color: #ef4444; box-shadow: 0 0 0 3px rgba(239, 68, 68, 0.1)
::placeholder → color: #9ca3af
:disabled    → background: #F9FAFB; color: #9ca3af
```

**Labels:** 14px, weight 500, colour `#374151`, margin-bottom 8px.

**Helper text:** 13px, weight 400, colour `#6b7280`, margin-top 6px.

**Error messages:** 13px, weight 500, colour `#ef4444`, margin-top 6px.

## Links

```css
color: #3b82f6
text-decoration: none
font-weight: 500
transition: color 200ms ease-in-out

:hover  → color: #2563eb; text-decoration: underline; text-underline-offset: 3px
:active → color: #1d4ed8
```

## Cards

```css
background: #FFFFFF
border: 1px solid #E5E7EB
border-radius: 16px
padding: 28px
transition: all 200ms ease-in-out

Interactive cards:
:hover → border-color: #D1D5DB; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.06); transform: translateY(-2px)
```

**Feature cards** (with icon): Add 48px icon container at top with `#eff6ff` background circle and `#3b82f6` icon.

## Navigation

```css
Top bar:
  background: #FFFFFF
  border-bottom: 1px solid #E5E7EB
  height: 68px
  padding: 0 24px

Nav links:
  color: #6b7280
  font-size: 15px
  font-weight: 500
  border-radius: 8px
  padding: 8px 16px
  :hover  → color: #111827; background: #F9FAFB
  :active → color: #3b82f6; background: #eff6ff

Mobile nav:
  Full-width overlay, slide down from top
  background: #FFFFFF
  padding: 16px
```
