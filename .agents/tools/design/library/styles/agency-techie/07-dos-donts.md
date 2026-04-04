<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agency Techie — Do's and Don'ts

## Do's

1. **Do** use monospace fonts for data, IDs, timestamps, code, and anything machine-generated
2. **Do** rely on border colour shifts and background tints for hierarchy over heavy shadows
3. **Do** keep transitions to 150ms — fast enough to feel instant, slow enough to register
4. **Do** use the cyan accent sparingly — one primary action per viewport section maximum
5. **Do** maintain a minimum contrast ratio of 4.5:1 for body text and 3:1 for large text
6. **Do** use the `Surface 3` background (`#243044`) for hover and selected states in lists and tables
7. **Do** test all colour combinations against WCAG AA on the actual background they'll appear on

## Don'ts

1. **Don't** use gradients — this system is flat by conviction, not by laziness
2. **Don't** use more than two type weights on a single component (e.g., 400 + 600 is the max)
3. **Don't** round corners beyond 6px — sharp geometry is core to the identity
4. **Don't** use pure white (`#ffffff`) for text — `#e2e8f0` is the ceiling
5. **Don't** animate layout properties (width, height, margin) — only opacity, transform, colour, box-shadow
6. **Don't** use light-mode defaults and "invert" them — design natively for dark backgrounds
7. **Don't** place cyan text on surfaces lighter than `#1c2333` — contrast drops below acceptable levels
