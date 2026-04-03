# IBM Design: Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Small (sm) | 320px | Single column, hamburger nav, 16px margins |
| Medium (md) | 672px | 2-column grids begin, expanded content |
| Large (lg) | 1056px | Full navigation visible, 3-4 column grids |
| X-Large (xlg) | 1312px | Maximum content density, wide layouts |
| Max | 1584px | Maximum content width, centered with margins |

## Touch Targets

- Button height: 48px default, minimum 40px (compact)
- Navigation links: 48px row height for touch
- Input height: 40px default, 48px large
- Icon buttons: 48px square touch target
- Mobile menu items: full-width 48px rows

## Collapsing Strategy

- Hero: 60px display → 42px → 32px heading as viewport narrows
- Navigation: full horizontal masthead → hamburger with slide-out panel
- Grid: 4-column → 2-column → single column
- Tiles/cards: horizontal grid → vertical stack
- Images: maintain aspect ratio, max-width 100%
- Footer: multi-column link groups → stacked single column
- Section padding: 48px → 32px → 16px

## Image Behavior

- Responsive images with `max-width: 100%`
- Product illustrations scale proportionally
- Hero images may shift from side-by-side to stacked below
- Data visualizations maintain aspect ratio with horizontal scroll on mobile
