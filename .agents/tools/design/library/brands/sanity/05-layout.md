# Design System: Sanity — Layout Principles

## Spacing System

Base unit: **8px**

| Token | Value | Usage |
|-------|-------|-------|
| space-1 | 1px | Hairline gaps, border-like spacing |
| space-2 | 2px | Minimal internal padding |
| space-3 | 4px | Tight component internal spacing |
| space-4 | 6px | Small element gaps |
| space-5 | 8px | Base unit -- button padding, input padding, badge padding |
| space-6 | 12px | Standard component gap, button horizontal padding |
| space-7 | 16px | Section internal padding, card spacing |
| space-8 | 24px | Large component padding, card internal spacing |
| space-9 | 32px | Section padding, container gutters |
| space-10 | 48px | Large section vertical spacing |
| space-11 | 64px | Major section breaks |
| space-12 | 96-120px | Hero vertical padding, maximum section spacing |

## Grid & Container

- Max content width: ~1440px (inferred from breakpoints)
- Page gutter: 32px on desktop, 16px on mobile
- Content sections use full-bleed backgrounds with centered, max-width content
- Multi-column layouts: 2-3 columns on desktop, single column on mobile
- Card grids: CSS Grid with consistent gaps (16-24px)

## Whitespace Philosophy

Sanity uses aggressive vertical spacing between sections (64-120px) to create breathing room on the dark canvas. Within sections, spacing is tighter (16-32px), creating dense information clusters separated by generous voids. This rhythm gives the page a "slides" quality -- each section feels like its own focused frame.

## Border Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| radius-xs | 3px | Inputs, textareas, subtle rounding |
| radius-sm | 4-5px | Secondary buttons, small cards, tags |
| radius-md | 6px | Standard cards, containers |
| radius-lg | 12px | Large cards, feature containers, forms |
| radius-pill | 99999px | Primary buttons, badges, nav pills |
