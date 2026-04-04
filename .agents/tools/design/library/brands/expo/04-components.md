# Design System: Expo — Component Stylings

## Buttons

**Primary (White on border)**

- Background: Pure White (`#ffffff`)
- Text: Near Black (`#1c2024`)
- Padding: 0px 12px (compact, content-driven height)
- Border: thin solid Input Border (`1px solid #d9d9e0`)
- Radius: subtly rounded (6px)
- Shadow: subtle combined shadow on hover
- The understated default — clean, professional, unheroic

**Primary Pill**

- Same as Primary but with pill-shaped radius (9999px)
- Used for hero CTAs and high-emphasis actions
- The extra roundness signals "start here"

**Dark Primary**

- Background: Expo Black (`#000000`)
- Text: Pure White (`#ffffff`)
- Pill-shaped (9999px) or generously rounded (32–36px)
- No border (black IS the border)
- The maximum-emphasis CTA — reserved for primary conversion actions

## Cards & Containers

- Background: Pure White (`#ffffff`) — clearly lifted from Cloud Gray page
- Border: thin solid Border Lavender (`1px solid #e0e1e6`) for standard cards
- Radius: comfortably rounded (8px) for standard cards; generously rounded (16–24px) for featured containers
- Shadow Level 1: Whisper (`rgba(0,0,0,0.08) 0px 3px 6px, rgba(0,0,0,0.07) 0px 2px 4px`) — barely perceptible lift
- Shadow Level 2: Standard (`rgba(0,0,0,0.1) 0px 10px 20px, rgba(0,0,0,0.05) 0px 3px 6px`) — clear floating elevation
- Hover: likely subtle shadow deepening or background shift

## Inputs & Forms

- Background: Pure White (`#ffffff`)
- Text: Near Black (`#1c2024`)
- Border: thin solid Input Border (`1px solid #d9d9e0`)
- Padding: 0px 12px (inline with button sizing)
- Radius: subtly rounded (6px)
- Focus: blue ring shadow via CSS custom property

## Navigation

- Sticky top nav on transparent/blurred background
- Logo: Expo wordmark in black
- Links: Near Black (`#1c2024`) or Slate Gray (`#60646c`) at 14–16px Inter weight 500
- CTA: Black pill button ("Sign Up") on the right
- GitHub star badge as social proof
- Status indicator ("All Systems Operational") with green dot

## Image Treatment

- Product screenshots and device mockups are the visual heroes
- Generously rounded corners (24px) on video and image containers
- Screenshots shown in realistic device frames
- Dark UI screenshots provide contrast against the light canvas
- Full-bleed within rounded containers

## Distinctive Components

**Universe React Logo**

- Animated/illustrated React logo as the visual centerpiece
- Connects Expo's identity to the React ecosystem
- The only illustrative element on an otherwise photographic page

**Device Preview Grid**

- Multiple device types (phone, tablet, web) shown simultaneously
- Demonstrates cross-platform capability visually
- Each device uses realistic device chrome

**Status Badge**

- "All Systems Operational" pill in the nav
- Green dot + text — compact trust signal
- Pill-shaped (36px radius)
