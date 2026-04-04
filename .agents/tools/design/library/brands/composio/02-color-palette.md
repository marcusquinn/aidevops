# Design System: Composio — Color Palette & Roles

## Primary

- **Composio Cobalt** (`#0007cd`): The core brand color — a deep, saturated blue used sparingly for high-priority interactive elements and brand moments. It anchors the identity with quiet intensity.

## Secondary & Accent

- **Electric Cyan** (`#00ffff`): The attention-grabbing accent — used at low opacity (`rgba(0,255,255,0.12)`) for glowing button backgrounds and card highlights. At full saturation, it serves as the energetic counterpoint to the dark canvas.
- **Signal Blue** (`#0089ff` / `rgb(0,137,255)`): Used for select button borders and interactive focus states, bridging the gap between Cobalt and Cyan.
- **Ocean Blue** (`#0096ff` / `rgb(0,150,255)`): Accent border color on CTA buttons, slightly warmer than Signal Blue.

## Surface & Background

- **Void Black** (`#0f0f0f`): The primary page background — not pure black, but a hair warmer, reducing eye strain on dark displays.
- **Pure Black** (`#000000`): Used for card interiors and deep-nested containers, creating a subtle depth distinction from the page background.
- **Charcoal** (`#2c2c2c` / `rgb(44,44,44)`): Used for secondary button borders and divider lines on dark surfaces.

## Neutrals & Text

- **Pure White** (`#ffffff`): Primary heading and high-emphasis text color on dark surfaces.
- **Muted Smoke** (`#444444`): De-emphasized body text, metadata, and tertiary content.
- **Ghost White** (`rgba(255,255,255,0.6)`): Secondary body text and link labels — visible but deliberately receded.
- **Whisper White** (`rgba(255,255,255,0.5)`): Tertiary button text and placeholder content.
- **Phantom White** (`rgba(255,255,255,0.2)`): Subtle button backgrounds and deeply receded UI chrome.

## Semantic & Accent

- **Border Mist 12** (`rgba(255,255,255,0.12)`): Highest-opacity border treatment — used for prominent card edges and content separators.
- **Border Mist 10** (`rgba(255,255,255,0.10)`): Standard container borders on dark surfaces.
- **Border Mist 08** (`rgba(255,255,255,0.08)`): Subtle section dividers and secondary card edges.
- **Border Mist 06** (`rgba(255,255,255,0.06)`): Near-invisible containment borders for background groupings.
- **Border Mist 04** (`rgba(255,255,255,0.04)`): The faintest border — used for atmospheric separation only.
- **Light Border** (`#e0e0e0` / `rgb(224,224,224)`): Reserved for light-surface contexts (rare on this site).

## Gradient System

- **Cyan Glow**: Radial gradients using `#00ffff` at very low opacity, creating bioluminescent halos behind cards and feature sections.
- **Blue-to-Black Fade**: Linear gradients from Composio Cobalt (`#0007cd`) fading into Void Black (`#0f0f0f`), used in hero backgrounds and section transitions.
- **White Fog**: Bottom-of-page gradient transitioning from dark to a diffused white/gray, creating an atmospheric "horizon line" effect near the footer.
