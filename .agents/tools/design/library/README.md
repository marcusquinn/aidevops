# Design Library

AI-readable design system examples for inspiration and reference. Each `DESIGN.md` file follows the [Google Stitch DESIGN.md format](https://stitch.withgoogle.com/docs/design-md/format/) with 9 sections capturing a complete visual design system.

## Structure

```text
library/
├── _template/                 -- Base templates for generating new DESIGN.md + previews
│   ├── DESIGN.md.template     -- Skeleton with section placeholders
│   └── preview.html.template  -- Parameterised HTML/CSS for visual catalogue (light+dark)
├── brands/                    -- Real brand examples (55 sites, educational use)
│   └── {brand}/DESIGN.md
└── styles/                    -- Archetype style templates (original, not brand-tied)
    └── {style}/DESIGN.md
```

## Brands

Extracted from publicly visible CSS values of real websites. Source: [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md) (MIT License).

### By Category

**AI & Machine Learning**: claude, cohere, elevenlabs, minimax, mistral.ai, ollama, opencode.ai, replicate, runwayml, together.ai, voltagent, x.ai

**Developer Tools**: cursor, expo, linear.app, lovable, mintlify, posthog, raycast, resend, sentry, supabase, superhuman, vercel, warp, zapier

**Infrastructure & Cloud**: clickhouse, composio, hashicorp, mongodb, sanity, stripe

**Design & Productivity**: airtable, cal, clay, figma, framer, intercom, miro, notion, pinterest, webflow

**Fintech & Crypto**: coinbase, kraken, revolut, wise

**Enterprise & Consumer**: airbnb, apple, bmw, ibm, nvidia, spacex, spotify, uber

### Usage

```bash
# Copy a brand example as starting point
cp .agents/tools/design/library/brands/stripe/DESIGN.md ./DESIGN.md

# Then customise colours, typography, and component specs for your project
```

## Styles

Original archetype templates -- generic starting points not tied to any brand.

| Style | Best For | Mood |
|-------|----------|------|
| `corporate-traditional` | Enterprise, finance, legal, government | Conservative, trustworthy, structured |
| `corporate-modern` | SaaS B2B, tech enterprise, professional services | Clean, confident, contemporary |
| `corporate-friendly` | Healthcare, education, HR, customer-facing enterprise | Approachable, warm, human |
| `agency-techie` | Dev agencies, tech consultancies, API products | Dark, code-forward, precise |
| `agency-creative` | Design studios, marketing agencies, portfolios | Bold, expressive, dynamic |
| `agency-feminine` | Beauty, wellness, lifestyle, fashion-adjacent | Soft, elegant, refined |
| `startup-bold` | Consumer apps, marketplaces, social platforms | Energetic, vibrant, attention-grabbing |
| `startup-minimal` | Developer tools, productivity, micro-SaaS | Clean, focused, no-nonsense |
| `developer-dark` | CLI tools, DevOps, IDE themes, terminal apps | Dark-first, monospace, technical |
| `editorial-clean` | Blogs, magazines, newsletters, documentation | Reading-optimised, serif, spacious |
| `luxury-premium` | High-end products, automotive, real estate | Restrained, cinematic, exclusive |
| `playful-vibrant` | Children's apps, gaming, entertainment, social | Bright, rounded, animated |

### Usage

```bash
# Copy a style archetype as starting point
cp .agents/tools/design/library/styles/startup-minimal/DESIGN.md ./DESIGN.md

# Spin the colour palette to make it yours
# See: tools/design/colour-palette.md
```

## Disclaimer

The brand DESIGN.md examples in `brands/` are extracted from publicly visible CSS values of third-party websites. They are provided for **educational and design inspiration purposes only**. We do not claim ownership of any brand's visual identity. All trademarks, logos, and brand names belong to their respective owners. These documents exist to help AI agents understand design patterns and generate consistent UI.

## Related

- `tools/design/design-md.md` -- DESIGN.md format specification and workflows
- `tools/design/brand-identity.md` -- Strategic brand identity (upstream input)
- `tools/design/colour-palette.md` -- Palette generation and spinning
- `tools/design/ui-ux-inspiration.md` -- URL study extraction workflow
- `templates/DESIGN.md.template` -- Skeleton for new projects
- `CREDITS.md` -- Attribution for sources
