# Design System: Startup Minimal — Do's and Don'ts

## Do's

1. **Do** let borders do the heavy lifting — 1px `#e5e7eb` is the system's workhorse
2. **Do** use one accent colour (`#2563eb`) consistently — diluting it with secondary colours weakens focus
3. **Do** snap every spacing value to the 4px grid — zero exceptions
4. **Do** use `#fafafa` vs `#ffffff` background shifts for section differentiation (not colour washes)
5. **Do** keep component padding tight (8–12px on buttons, 24px on cards) — this isn't a luxury brand
6. **Do** use monospace for code, IDs, and technical values — and nowhere else
7. **Do** test at 1x zoom on a 1080p screen — this is where most users will experience it

## Don'ts

1. **Don't** use gradients, patterns, or decorative backgrounds — ever
2. **Don't** use coloured shadows — shadows are `rgba(0,0,0,...)` only
3. **Don't** introduce a second accent colour — if you need hierarchy, use weight or size
4. **Don't** use border-radius above 8px on standard components (the system doesn't do "playful")
5. **Don't** add hover animations to non-interactive elements — if it doesn't do something, it shouldn't move
6. **Don't** use font weights below 400 or above 700 — the range is 400 (body), 500 (labels/buttons), 600 (headings)
7. **Don't** use text larger than 48px outside of a dedicated hero section
