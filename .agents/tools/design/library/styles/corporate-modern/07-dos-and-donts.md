# Design System: Corporate Modern — Do's and Don'ts

## Do's

1. **Do** maintain the 8px spacing grid rigorously — every margin and padding should be a multiple of 8 (4 for fine adjustments)
2. **Do** use the teal accent sparingly — it marks primary actions and key navigation, not decoration
3. **Do** rely on whitespace and typography weight for hierarchy, not colour variation
4. **Do** ensure all interactive elements have clear hover, focus, and disabled states
5. **Do** use consistent border-radius within component groups (8px for form elements, 12px for cards)
6. **Do** keep the navigation bar clean — no more than 6 top-level items
7. **Do** use the semantic colour palette for all status indicators
8. **Do** test all layouts at every breakpoint — no component should break between 320px and 1440px

## Don'ts

1. **Don't** use more than three font weights on a single view (400, 500/600, 700)
2. **Don't** apply the teal accent to large background areas — it's for interactive elements and small highlights only
3. **Don't** use drop shadows on flat elements like dividers or inline badges
4. **Don't** mix border-radius values within the same component (e.g., 8px top, 12px bottom)
5. **Don't** use colour alone to convey meaning — always pair with text, icons, or patterns
6. **Don't** place body text directly on coloured backgrounds without checking contrast (minimum WCAG AA 4.5:1)
7. **Don't** animate layout properties (width, height, margin) — only transform, opacity, colour, and box-shadow
8. **Don't** nest cards within cards — flatten the information hierarchy instead
