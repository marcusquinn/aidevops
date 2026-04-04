<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Nothing Design System — Anti-Patterns

- No gradients, shadows, or blur.
- No skeleton loading. Use `[LOADING...]` or segmented spinner.
- No toasts. Use inline status: `[SAVED]`, `[ERROR: ...]`
- No illustrations, mascots, or multi-paragraph empty states.
- No zebra striping.
- No filled/multi-color icons or emoji.
- No parallax, scroll-jacking, or gratuitous animation.
- No spring/bounce easing. Use ease-out.
- No border-radius > 16px. Buttons: pill (999px) or technical (4-8px).
- Data viz: differentiate with **opacity** (100%/60%/30%) or **pattern** (solid/striped/dotted) before color.
