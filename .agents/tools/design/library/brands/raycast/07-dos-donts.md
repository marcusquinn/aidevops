# Design System: Raycast — Do's and Don'ts

## Do

- Use `#07080a` (not pure black) as the background — the blue-cold tint is essential to the Raycast feel
- Apply positive letter-spacing (+0.2px) on body text — this is deliberately different from most dark UIs
- Use multi-layer shadows with inset highlights for interactive elements — the macOS-native depth is signature
- Keep Raycast Red (`#FF6363`) as punctuation, not pervasive — reserve it for hero moments and error states
- Use `rgba(255, 255, 255, 0.06)` borders for card containment — barely visible, structurally essential
- Apply weight 500 as the body text baseline — medium weight improves dark-mode legibility
- Use pill shapes (86px+ radius) for primary CTAs, rectangular shapes (6px–8px) for secondary actions
- Enable OpenType features `calt`, `kern`, `liga`, `ss03` on all Inter text
- Use opacity transitions (hover: opacity 0.6) for button interactions, not color changes

## Don't

- Use pure black (`#000000`) as the background — the blue tint differentiates Raycast from generic dark themes
- Apply negative letter-spacing on body text — Raycast deliberately uses positive spacing for readability
- Use Raycast Blue as the primary accent for everything — blue is for interactive/info, red is the brand color
- Create single-layer flat shadows — the multi-layer inset system is core to the macOS-native aesthetic
- Use regular weight (400) for body text when 500 is available — the extra weight prevents dark-mode text from feeling thin
- Mix warm and cool borders — stick to the cool gray (`hsl(195, 5%, 15%)`) border palette
- Apply heavy drop shadows without inset companions — shadows always come in pairs (outer + inset)
- Use decorative elements, gradients, or colorful backgrounds — the dark void is the stage, content is the performer
