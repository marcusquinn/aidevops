# Design System: Playful Vibrant — Component Stylings

## Buttons

**Primary Button:**

```css
background: linear-gradient(135deg, #6366f1, #8b5cf6)
color: #FFFFFF
padding: 14px 32px
border: none
border-radius: 16px
font-size: 15px
font-weight: 700
cursor: pointer
box-shadow: 0 4px 14px rgba(99, 102, 241, 0.35)
transition: all 200ms cubic-bezier(0.34, 1.56, 0.64, 1)

:hover    → transform: translateY(-2px); box-shadow: 0 6px 20px rgba(99, 102, 241, 0.4)
:active   → transform: translateY(0px); box-shadow: 0 2px 8px rgba(99, 102, 241, 0.3)
:focus    → outline: 3px solid rgba(99, 102, 241, 0.4); outline-offset: 2px
:disabled → background: #E5E7EB; color: #9ca3af; box-shadow: none; cursor: not-allowed
```

**Secondary Button:**

```css
background: #FFFFFF
color: #6366f1
padding: 14px 32px
border: 2px solid #6366f1
border-radius: 16px
font-size: 15px
font-weight: 700
transition: all 200ms cubic-bezier(0.34, 1.56, 0.64, 1)

:hover    → background: #eef2ff; transform: translateY(-2px)
:active   → background: #e0e7ff; transform: translateY(0px)
:disabled → border-color: #E5E7EB; color: #9ca3af
```

**Ghost Button:**

```css
background: transparent
color: #6366f1
padding: 14px 32px
border: none
border-radius: 16px
font-size: 15px
font-weight: 700

:hover    → background: #eef2ff
:active   → background: #e0e7ff
```

**Accent Button (urgent/fun CTA):**

```css
background: linear-gradient(135deg, #f43f5e, #e11d48)
color: #FFFFFF
padding: 14px 32px
border-radius: 16px
font-size: 15px
font-weight: 700
box-shadow: 0 4px 14px rgba(244, 63, 94, 0.35)

:hover    → transform: translateY(-2px); box-shadow: 0 6px 20px rgba(244, 63, 94, 0.4)
:active   → transform: translateY(0px)
```

## Inputs

```css
background: #FFFFFF
border: 2px solid #E5E7EB
border-radius: 16px
padding: 14px 18px
font-size: 16px
font-weight: 400
color: #1e1b4b
transition: all 200ms ease

:hover       → border-color: #c7d2fe
:focus       → border-color: #6366f1; box-shadow: 0 0 0 4px rgba(99, 102, 241, 0.15)
:error       → border-color: #f43f5e; box-shadow: 0 0 0 4px rgba(244, 63, 94, 0.1)
:success     → border-color: #10b981; box-shadow: 0 0 0 4px rgba(16, 185, 129, 0.1)
::placeholder → color: #9ca3af
:disabled    → background: #F9FAFB; color: #9ca3af
```

**Labels:** 14px, weight 600, colour `#374151`, margin-bottom 8px.
**Helper text:** 13px, weight 400, colour `#6b7280`, margin-top 6px.
**Character counter:** 12px, colour `#9ca3af`, right-aligned.

## Links

```css
color: #6366f1
text-decoration: none
font-weight: 600
transition: color 200ms ease

:hover  → color: #4f46e5; text-decoration: underline; text-decoration-style: wavy; text-underline-offset: 4px
:active → color: #4338ca
```

## Cards

```css
background: #FFFFFF
border: none
border-radius: 20px
padding: 28px
box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06)
transition: all 200ms cubic-bezier(0.34, 1.56, 0.64, 1)

Interactive cards:
:hover → transform: translateY(-4px) scale(1.01); box-shadow: 0 12px 32px rgba(0, 0, 0, 0.1)
```

**Feature cards** with colour accent: Add a 4px top border in one of the extended palette colours.
**Achievement cards:** Gold (`#f59e0b`) top border with `#fffbeb` background tint.

## Navigation

```css
Top bar:
  background: #FFFFFF
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.04)
  height: 68px
  padding: 0 24px
  border-radius: 0 (full width)

Nav links:
  color: #6b7280
  font-size: 15px
  font-weight: 600
  border-radius: 12px
  padding: 8px 16px
  transition: all 200ms ease
  :hover  → color: #6366f1; background: #eef2ff
  :active → color: #4f46e5; background: #e0e7ff

Active indicator:
  background: #eef2ff
  color: #6366f1
  (or bottom border 3px in #6366f1)

Mobile nav:
  Bottom tab bar with icons + labels
  Active tab: #6366f1 icon + text
  Inactive: #9ca3af
```

## Badges & Tags

```css
Notification badge:
  background: #f43f5e
  color: #FFFFFF
  font-size: 11px
  font-weight: 700
  min-width: 20px
  height: 20px
  border-radius: 9999px
  padding: 0 6px

Tag:
  background: #eef2ff
  color: #6366f1
  font-size: 12px
  font-weight: 600
  padding: 4px 12px
  border-radius: 9999px
```
