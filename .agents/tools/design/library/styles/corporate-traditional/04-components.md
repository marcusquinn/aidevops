# Design System: Corporate Traditional — Component Stylings

## Buttons

**Primary Button:**

```css
background: #1B365D
color: #FFFFFF
padding: 12px 28px
border: none
border-radius: 4px
font-family: system-ui, sans-serif
font-size: 15px
font-weight: 600
letter-spacing: 0.02em
text-transform: none
cursor: pointer
transition: background 200ms ease

:hover    → background: #2A4A7F
:active   → background: #0F2341
:focus    → outline: 2px solid #B8860B; outline-offset: 2px
:disabled → background: #9CA3AF; cursor: not-allowed
```

**Secondary Button:**

```css
background: transparent
color: #1B365D
padding: 12px 28px
border: 1.5px solid #1B365D
border-radius: 4px
font-size: 15px
font-weight: 600

:hover    → background: #EEF0F4
:active   → background: #D1D5DB
:disabled → border-color: #D1D5DB; color: #9CA3AF
```

**Ghost Button:**

```css
background: transparent
color: #1B365D
padding: 12px 28px
border: none
border-radius: 4px
font-size: 15px
font-weight: 600
text-decoration: underline
text-underline-offset: 3px

:hover    → color: #2A4A7F; background: #F5F5F0
:active   → color: #0F2341
```

## Inputs

```css
background: #FFFFFF
border: 1px solid #D1D5DB
border-radius: 4px
padding: 10px 14px
font-family: system-ui, sans-serif
font-size: 16px
color: #333333
transition: border-color 200ms ease

:hover       → border-color: #9CA3AF
:focus       → border-color: #1B365D; box-shadow: 0 0 0 3px rgba(27, 54, 93, 0.12)
:error       → border-color: #991B1B; box-shadow: 0 0 0 3px rgba(153, 27, 27, 0.1)
::placeholder → color: #9CA3AF
:disabled    → background: #F5F5F0; color: #9CA3AF
```

**Labels:** 14px, weight 600, colour `#333333`, margin-bottom 6px.

## Links

```css
color: #1B365D
text-decoration: underline
text-underline-offset: 3px
text-decoration-color: #D1D5DB
transition: text-decoration-color 200ms ease

:hover  → text-decoration-color: #1B365D
:active → color: #0F2341
```

Gold accent links (CTAs): `color: #B8860B`, same underline treatment.

## Cards

```css
background: #FFFFFF
border: 1px solid #D1D5DB
border-radius: 4px
padding: 24px 28px
box-shadow: 0 1px 3px rgba(27, 54, 93, 0.06)

:hover → box-shadow: 0 2px 8px rgba(27, 54, 93, 0.1) (if interactive)
```

## Navigation

```css
Top bar:
  background: #1B365D
  color: #FFFFFF
  height: 64px
  padding: 0 32px
  font-size: 14px
  font-weight: 500
  letter-spacing: 0.02em

Nav links:
  color: rgba(255, 255, 255, 0.85)
  :hover → color: #FFFFFF; border-bottom: 2px solid #B8860B
  :active → color: #FFFFFF; border-bottom: 2px solid #FFFFFF

Dropdown:
  background: #FFFFFF
  border: 1px solid #D1D5DB
  box-shadow: 0 4px 12px rgba(27, 54, 93, 0.12)
  border-radius: 4px
```
