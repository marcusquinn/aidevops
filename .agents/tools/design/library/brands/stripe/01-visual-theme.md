# Visual Theme & Atmosphere

Stripe's website is the gold standard of fintech design -- a system that manages to feel simultaneously technical and luxurious, precise and warm. The page opens on a clean white canvas (`#ffffff`) with deep navy headings (`#061b31`) and a signature purple (`#533afd`) that functions as both brand anchor and interactive accent. This isn't the cold, clinical purple of enterprise software; it's a rich, saturated violet that reads as confident and premium. The overall impression is of a financial institution redesigned by a world-class type foundry.

The custom `sohne-var` variable font is the defining element of Stripe's visual identity. Every text element enables the OpenType `"ss01"` stylistic set, which modifies character shapes for a distinctly geometric, modern feel. At display sizes (48px-56px), sohne-var runs at weight 300 -- an extraordinarily light weight for headlines that creates an ethereal, almost whispered authority. This is the opposite of the "bold hero headline" convention; Stripe's headlines feel like they don't need to shout. The negative letter-spacing (-1.4px at 56px, -0.96px at 48px) tightens the text into dense, engineered blocks. At smaller sizes, the system also uses weight 300 with proportionally reduced tracking, and tabular numerals via `"tnum"` for financial data display.

What truly distinguishes Stripe is its shadow system. Rather than the flat or single-layer approach of most sites, Stripe uses multi-layer, blue-tinted shadows: the signature `rgba(50,50,93,0.25)` combined with `rgba(0,0,0,0.1)` creates shadows with a cool, almost atmospheric depth -- like elements are floating in a twilight sky. The blue-gray undertone of the primary shadow color (50,50,93) ties directly to the navy-purple brand palette, making even elevation feel on-brand.

## Key Characteristics

- sohne-var with OpenType `"ss01"` on all text -- a custom stylistic set that defines the brand's letterforms
- Weight 300 as the signature headline weight -- light, confident, anti-convention
- Negative letter-spacing at display sizes (-1.4px at 56px, progressive relaxation downward)
- Blue-tinted multi-layer shadows using `rgba(50,50,93,0.25)` -- elevation that feels brand-colored
- Deep navy (`#061b31`) headings instead of black -- warm, premium, financial-grade
- Conservative border-radius (4px-8px) -- nothing pill-shaped, nothing harsh
- Ruby (`#ea2261`) and magenta (`#f96bee`) accents for gradient and decorative elements
- `SourceCodePro` as the monospace companion for code and technical labels
