<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: OpenCode — Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile | <640px | Single column, reduced padding, heading scales down |
| Tablet | 640-1024px | Content width expands, slight padding increase |
| Desktop | >1024px | Full content width (~800-900px centered), maximum whitespace |

## Touch Targets

- Buttons with 4px 20px padding provide adequate horizontal touch area
- Input fields with 20px padding ensure comfortable mobile typing
- Tab items at 16px with tight line-height may need mobile adaptation

## Collapsing Strategy

- Hero heading: 38px → 28px → 24px on smaller screens
- Navigation: horizontal links → hamburger/drawer on mobile
- Feature lists: maintain single-column, reduce horizontal padding
- Terminal hero: maintain full-width, reduce internal padding
- Footer columns: multi-column → stacked single column
- Section spacing: 96px → 64px → 48px on mobile

## Image Behavior

- Terminal screenshots maintain aspect ratio and border treatment
- Full-width elements scale proportionally
- Monospace type maintains readability at all sizes due to fixed-width nature
