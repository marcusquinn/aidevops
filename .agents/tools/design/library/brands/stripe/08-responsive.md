# Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile | <640px | Single column, reduced heading sizes, stacked cards |
| Tablet | 640-1024px | 2-column grids, moderate padding |
| Desktop | 1024-1280px | Full layout, 3-column feature grids |
| Large Desktop | >1280px | Centered content with generous margins |

## Touch Targets

- Buttons use comfortable padding (8px-16px vertical)
- Navigation links at 14px with adequate spacing
- Badges have 6px horizontal padding minimum for tap targets
- Mobile nav toggle with 6px radius button

## Collapsing Strategy

- Hero: 56px display -> 32px on mobile, weight 300 maintained
- Navigation: horizontal links + CTAs -> hamburger toggle
- Feature cards: 3-column -> 2-column -> single column stacked
- Dark brand sections: maintain full-width treatment, reduce internal padding
- Financial data tables: horizontal scroll on mobile
- Section spacing: 64px+ -> 40px on mobile
- Typography scale compresses: 56px -> 48px -> 32px hero sizes across breakpoints

## Image Behavior

- Dashboard/product screenshots maintain blue-tinted shadow at all sizes
- Hero gradient decorations simplify on mobile
- Code blocks maintain `SourceCodePro` treatment, may horizontally scroll
- Card images maintain consistent 4px-6px border-radius
