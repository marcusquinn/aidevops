# Design System: Developer Dark — Do's and Don'ts

## Do

- Use monospace font for headings, buttons, labels, and code -- it's the design language
- Use semantic colours consistently: green=success/go, amber=warning/caution, red=error/stop
- Keep border-radius at 4px for all standard elements -- consistency over variety
- Use the inset (`#0d1117`) background for code blocks and terminal output
- Provide clear keyboard focus indicators (2px green outline)
- Use uppercase for button text and navigation labels
- Keep padding compact (8px, 12px, 16px) -- density is a feature
- Use border-driven depth rather than shadow-driven depth
- Include a command palette (Cmd+K) pattern for power users

## Don't

- Never use gradients -- flat colours only, like a terminal
- Never use rounded corners beyond 6px (except pills for badges)
- Never use decorative elements, illustrations, or ornamental dividers
- Never use more than 3 font weights (400, 600, 700)
- Never make interactive elements smaller than 32x32px even in dense layouts
- Never use colour as the only indicator -- always pair with text/icon
- Never animate beyond 150ms for interface feedback -- developers expect instant response
- Never use light mode as the default -- dark is the primary and expected theme
- Never use serif fonts anywhere in the system
