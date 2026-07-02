<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Luxury Premium Components

## 7. Components

### Buttons

**Primary Button:**

```css
background: #c9a96e
color: #000000
padding: 16px 48px
border: none
border-radius: 0px
font-family: system-ui, sans-serif
font-size: 12px
font-weight: 400
letter-spacing: 0.15em
text-transform: uppercase
cursor: pointer
transition: all 400ms ease

:hover    -> background: #d4b87a
:active   -> background: #b08d50
:focus    -> outline: 1px solid #c9a96e; outline-offset: 4px
:disabled -> background: #333333; color: #666666; cursor: not-allowed
```

**Secondary Button:**

```css
background: transparent
color: #FFFFFF
padding: 16px 48px
border: 1px solid rgba(255, 255, 255, 0.3)
border-radius: 0px
font-size: 12px
font-weight: 400
letter-spacing: 0.15em
text-transform: uppercase
transition: all 400ms ease

:hover    -> border-color: #FFFFFF; color: #FFFFFF
:active   -> background: rgba(255, 255, 255, 0.05)
:disabled -> border-color: rgba(255, 255, 255, 0.1); color: rgba(255, 255, 255, 0.3)
```

**Ghost Button (text link):**

```css
background: transparent
color: #c9a96e
padding: 8px 0
border: none
font-size: 12px
font-weight: 400
letter-spacing: 0.15em
text-transform: uppercase
border-bottom: 1px solid rgba(201, 169, 110, 0.3)
transition: all 400ms ease

:hover    -> border-bottom-color: #c9a96e
:active   -> color: #b08d50
```

### Inputs

```css
background: #111111
border: 1px solid rgba(255, 255, 255, 0.1)
border-radius: 0px
padding: 14px 16px
font-family: system-ui, sans-serif
font-size: 14px
font-weight: 300
color: #FFFFFF
letter-spacing: 0.02em
transition: border-color 400ms ease

:hover       -> border-color: rgba(255, 255, 255, 0.2)
:focus       -> border-color: #c9a96e; box-shadow: none
:error       -> border-color: #f87171
::placeholder -> color: rgba(255, 255, 255, 0.3)
:disabled    -> background: #0a0a0a; color: rgba(255, 255, 255, 0.2)
```

**Labels:** 11px, weight 400, uppercase, letter-spacing 0.1em, colour `rgba(255,255,255,0.5)`, margin-bottom 8px.

### Links

```css
color: #c9a96e
text-decoration: none
font-weight: 300
letter-spacing: 0.02em
transition: color 400ms ease

:hover  -> color: #d4b87a
:active -> color: #b08d50
```

Navigation links (uppercase):

```css
color: rgba(255, 255, 255, 0.5)
font-size: 12px
letter-spacing: 0.15em
text-transform: uppercase

:hover  -> color: #FFFFFF
:active -> color: #c9a96e
```

### Cards

```css
background: #0a0a0a
border: 1px solid rgba(255, 255, 255, 0.06)
border-radius: 0px
padding: 0
overflow: hidden
transition: all 600ms ease

Image section: full-width, aspect 3:4 or 16:9
Content section: padding 32px

Interactive cards:
:hover -> border-color: rgba(255, 255, 255, 0.12); transform: translateY(-4px)
```

### Navigation

```css
Top bar:
  background: transparent (absolute positioned over hero)
  height: 80px
  padding: 0 48px
  transition: background 400ms ease

Scrolled state:
  background: rgba(0, 0, 0, 0.9)
  backdrop-filter: blur(12px)

Logo:
  font-family: "Cormorant Garamond", serif
  font-size: 28px
  font-weight: 300
  letter-spacing: 0.05em
  color: #FFFFFF

Nav links:
  font-size: 12px
  font-weight: 400
  letter-spacing: 0.15em
  text-transform: uppercase
  color: rgba(255, 255, 255, 0.5)
  :hover  -> color: #FFFFFF
  :active -> color: #c9a96e
```
