<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# 4. Component Stylings

## Buttons

**Primary Button:**

```css
background: #1a1a1a
color: #FAF8F5
padding: 12px 32px
border: none
border-radius: 4px
font-family: "Source Sans 3", system-ui, sans-serif
font-size: 15px
font-weight: 600
letter-spacing: 0.02em
cursor: pointer
transition: background 150ms ease

:hover    → background: #333333
:active   → background: #000000
:focus    → outline: 2px solid #4a6fa5; outline-offset: 2px
:disabled → background: #cccccc; color: #999999; cursor: not-allowed
```

**Secondary Button:**

```css
background: transparent
color: #1a1a1a
padding: 12px 32px
border: 1.5px solid #1a1a1a
border-radius: 4px
font-size: 15px
font-weight: 600

:hover    → background: #1a1a1a; color: #FAF8F5
:active   → background: #000000; color: #FAF8F5
:disabled → border-color: #cccccc; color: #999999
```

**Ghost Button (text link style):**

```css
background: transparent
color: #4a6fa5
padding: 8px 0
border: none
font-size: 15px
font-weight: 500
text-decoration: underline
text-underline-offset: 3px
text-decoration-thickness: 1px

:hover    → color: #364f75; text-decoration-thickness: 2px
:active   → color: #2a3d5c
```

## Inputs

```css
background: #FFFFFF
border: 1px solid #E8E4DF
border-radius: 4px
padding: 12px 16px
font-family: "Source Sans 3", system-ui, sans-serif
font-size: 16px
color: #1a1a1a
transition: border-color 150ms ease

:hover       → border-color: #999999
:focus       → border-color: #4a6fa5; box-shadow: 0 0 0 3px rgba(74, 111, 165, 0.1)
:error       → border-color: #c0392b
::placeholder → color: #999999
:disabled    → background: #F2EFE9; color: #999999
```

## Links (inline text)

```css
color: #4a6fa5
text-decoration: underline
text-decoration-color: rgba(74, 111, 165, 0.3)
text-underline-offset: 3px
text-decoration-thickness: 1px
transition: text-decoration-color 150ms ease

:hover   → text-decoration-color: #4a6fa5; text-decoration-thickness: 2px
:active  → color: #364f75
:visited → color: #6b5b8a (optional)
```

## Cards (article cards)

```css
background: transparent
border: none
padding: 0
margin-bottom: 48px

Article card layout:
  - Optional: full-width image (aspect 16:9 or 3:2), no border-radius
  - Category label: 12px/600, uppercase, letter-spacing 0.08em, colour #4a6fa5
  - Title: serif, 24px/700, colour #1a1a1a, margin-top 12px
  - Excerpt: 16px/400, colour #666666, line-height 1.6, margin-top 8px
  - Byline: 14px/500, colour #999999, margin-top 12px

:hover → title colour changes to #4a6fa5 (linked articles)
```

## Navigation

```css
Top bar:
  background: #FAF8F5
  border-bottom: 1px solid #E8E4DF
  height: 60px
  padding: 0 24px

Logo/masthead:
  font-family: "Playfair Display", serif
  font-size: 24px
  font-weight: 700
  color: #1a1a1a
  letter-spacing: -0.02em

Nav links:
  font-family: "Source Sans 3", sans-serif
  font-size: 14px
  font-weight: 500
  color: #666666
  letter-spacing: 0.03em
  text-transform: uppercase
  :hover  → color: #1a1a1a
  :active → color: #4a6fa5
```

## Pull Quotes

```css
font-family: "Playfair Display", serif
font-size: 28px
font-style: italic
font-weight: 400
line-height: 1.4
color: #1a1a1a
border-left: 3px solid #E8E4DF
padding-left: 24px
margin: 48px 0
```

## Code Blocks

```css
background: #F2EFE9
border: 1px solid #E8E4DF
border-radius: 4px
padding: 20px 24px
font-family: "JetBrains Mono", monospace
font-size: 14px
line-height: 1.6
color: #2d2d2d
overflow-x: auto
```
