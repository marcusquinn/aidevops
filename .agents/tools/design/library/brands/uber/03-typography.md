# Uber Design: Typography Rules

## Font Family

- **Headline / Display**: `UberMove`, with fallbacks: `UberMoveText, system-ui, Helvetica Neue, Helvetica, Arial, sans-serif`
- **Body / UI**: `UberMoveText`, with fallbacks: `system-ui, Helvetica Neue, Helvetica, Arial, sans-serif`

*Note: UberMove and UberMoveText are proprietary typefaces. For external implementations, use `system-ui` or Inter as the closest available substitute. The geometric, square-proportioned character of UberMove can be approximated with Inter or DM Sans.*

## Hierarchy

| Role | Font | Size | Weight | Line Height | Notes |
|------|------|------|--------|-------------|-------|
| Display / Hero | UberMove | 52px (3.25rem) | 700 | 1.23 (tight) | Maximum impact, billboard presence |
| Section Heading | UberMove | 36px (2.25rem) | 700 | 1.22 (tight) | Major section anchors |
| Card Title | UberMove | 32px (2rem) | 700 | 1.25 (tight) | Card and feature headings |
| Sub-heading | UberMove | 24px (1.5rem) | 700 | 1.33 | Secondary section headers |
| Small Heading | UberMove | 20px (1.25rem) | 700 | 1.40 | Compact headings, list titles |
| Nav / UI Large | UberMoveText | 18px (1.13rem) | 500 | 1.33 | Navigation links, prominent UI text |
| Body / Button | UberMoveText | 16px (1rem) | 400-500 | 1.25-1.50 | Standard body text, button labels |
| Caption | UberMoveText | 14px (0.88rem) | 400-500 | 1.14-1.43 | Metadata, descriptions, small links |
| Micro | UberMoveText | 12px (0.75rem) | 400 | 1.67 (relaxed) | Fine print, legal text |

## Principles

- **Bold headlines, medium body**: UberMove headings are exclusively weight 700 — every headline hits with billboard force. UberMoveText body and UI text uses 400-500, creating clear visual hierarchy through weight contrast.
- **Tight heading line-heights**: All headlines use line-heights between 1.22-1.40 — compact and punchy, designed for scanning rather than reading.
- **Functional typography**: No decorative type treatment anywhere. No letter-spacing, no text-transform, no ornamental sizing. Every text element serves a direct communication purpose.
- **Two fonts, strict roles**: UberMove is exclusively for headings. UberMoveText is exclusively for body, buttons, links, and UI. The boundary is never crossed.
