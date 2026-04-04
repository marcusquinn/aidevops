# Design System: Developer Dark — Component Stylings

## Buttons

**Primary (Green)**

- Background: `#4ade80`
- Text: `#111827` (dark on green for contrast)
- Border: none
- Radius: 4px
- Padding: 8px 16px
- Font: JetBrains Mono, 13px, weight 600, uppercase, letter-spacing 0.5px
- Hover: background `#22c55e`
- Focus: outline `2px solid #4ade80`, outline-offset `2px`
- Active: background `#16a34a`
- Disabled: opacity 0.4, cursor not-allowed

**Secondary (Ghost)**

- Background: transparent
- Text: `#f9fafb`
- Border: `1px solid #374151`
- Radius: 4px
- Padding: 8px 16px
- Hover: background `#1f2937`, border-color `#4b5563`
- Focus: outline `2px solid #4ade80`, outline-offset `2px`

**Danger**

- Background: `#ef4444`
- Text: `#ffffff`
- Border: none
- Radius: 4px
- Hover: background `#dc2626`

## Inputs

**Text Input**

- Background: `#0d1117`
- Text: `#f9fafb`
- Border: `1px solid #374151`
- Radius: 4px
- Padding: 8px 12px
- Font: JetBrains Mono, 14px, weight 400
- Placeholder: `#6b7280`
- Focus: border-color `#4ade80`, box-shadow `0 0 0 2px rgba(74, 222, 128, 0.2)`
- Error: border-color `#ef4444`, box-shadow `0 0 0 2px rgba(239, 68, 68, 0.2)`

## Links

- Default: `#3b82f6`, underline (body text links — accessibility requirement; see 07-dos-donts.md)
- Hover: `#60a5fa`, underline
- Active: `#2563eb`
- Code links: `#4ade80`, hover `#22c55e`

## Cards & Containers

- Background: `#1f2937`
- Border: `1px solid #374151`
- Radius: 4px
- Padding: 16px
- Shadow: none (border-driven depth)
- Hover: border-color `#4b5563`

## Navigation

- Sticky top bar, background `#111827` with border-bottom `1px solid #1f2937`
- Nav links: JetBrains Mono 13px, weight 500, `#9ca3af`
- Active link: `#4ade80`
- Hover: `#f9fafb`
- Logo/brand: JetBrains Mono 15px, weight 700, `#f9fafb`
