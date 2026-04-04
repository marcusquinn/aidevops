# Startup Bold — Component Stylings

## Buttons

### Primary Button

```css
background: #4f46e5
color: #ffffff
font: 14px/1 Plus Jakarta Sans, 600
padding: 12px 28px
border: none
border-radius: 12px
box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06)
transition: all 200ms ease-out

:hover    → background: #4338ca; box-shadow: 0 4px 16px rgba(79, 70, 229, 0.25); transform: translateY(-1px)
:active   → background: #3730a3; transform: translateY(0); box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06)
:focus    → outline: 2px solid #4f46e5; outline-offset: 2px
:disabled → background: #c7d2fe; cursor: not-allowed; transform: none
```

### Secondary Button

```css
background: #ffffff
color: #4f46e5
font: 14px/1 Plus Jakarta Sans, 600
padding: 12px 28px
border: 2px solid #4f46e5
border-radius: 12px

:hover    → background: #e0e7ff; border-color: #4338ca
:active   → background: #c7d2fe
:focus    → outline: 2px solid #4f46e5; outline-offset: 2px
:disabled → color: #9ca3af; border-color: #e5e7eb
```

### Ghost Button

```css
background: transparent
color: #6b7280
font: 14px/1 Plus Jakarta Sans, 500
padding: 12px 28px
border: none
border-radius: 12px

:hover    → color: #111827; background: rgba(79, 70, 229, 0.06)
:active   → background: rgba(79, 70, 229, 0.1)
```

### Accent Button (for secondary CTA — "Start Free", "Try Now")

```css
background: #10b981
color: #ffffff
font: 14px/1 Plus Jakarta Sans, 600
padding: 12px 28px
border: none
border-radius: 12px

:hover    → background: #059669; box-shadow: 0 4px 16px rgba(16, 185, 129, 0.2)
:active   → background: #047857
```

## Inputs

```css
background: #f9fafb
color: #111827
font: 15px Plus Jakarta Sans
padding: 12px 16px
border: 1.5px solid #e5e7eb
border-radius: 12px
transition: all 200ms ease

::placeholder → color: #9ca3af
:hover        → border-color: #d1d5db
:focus        → border-color: #4f46e5; background: #ffffff; box-shadow: 0 0 0 4px rgba(79, 70, 229, 0.1)
:invalid      → border-color: #ef4444
:disabled     → background: #f3f4f6; color: #9ca3af
```

## Links

```css
color: #4f46e5
font-weight: 500
text-decoration: none
transition: color 200ms ease

:hover  → color: #4338ca; text-decoration: underline; text-underline-offset: 3px
:active → color: #3730a3
```

## Cards

```css
background: #ffffff
border: 1px solid #e5e7eb
border-radius: 16px
padding: 28px
box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06)
transition: all 200ms ease-out

:hover → box-shadow: 0 4px 16px rgba(0, 0, 0, 0.08); transform: translateY(-2px)
```

## Navigation

```css
background: #ffffff
border-bottom: 1px solid #e5e7eb
height: 64px
logo: Plus Jakarta Sans 700 wordmark, 20px, #111827
nav-items: 15px Plus Jakarta Sans, 500, #6b7280
active-item: #111827, font-weight: 600
hover-item: #111827
cta-in-nav: small primary button with #4f46e5 background
```
