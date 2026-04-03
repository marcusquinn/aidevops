# Credits & Acknowledgements

Sources, inspirations, and third-party resources incorporated into or referenced by the AI DevOps framework.

## Design System

### DESIGN.md Standard

- **Google Stitch** -- Introduced the DESIGN.md concept as a companion to AGENTS.md for AI-readable design systems.
  - Overview: https://stitch.withgoogle.com/docs/design-md/overview
  - Format: https://stitch.withgoogle.com/docs/design-md/format/
  - Usage: https://stitch.withgoogle.com/docs/design-md/usage/

### Design Library (Brand Examples)

- **VoltAgent/awesome-design-md** (MIT License) -- Curated collection of DESIGN.md files extracted from popular websites.
  - Repository: https://github.com/VoltAgent/awesome-design-md
  - 55 brand design system examples imported into `.agents/tools/design/library/brands/`
  - Original preview HTML templates informed our parameterised preview template

> **Disclaimer**: The brand DESIGN.md examples in `library/brands/` are extracted from publicly visible CSS values of third-party websites. They are provided for educational and design inspiration purposes only. We do not claim ownership of any brand's visual identity. All trademarks, logos, and brand names belong to their respective owners.

### Nothing Design Skill

- **dominikmartn/nothing-design-skill** -- Nothing-inspired UI/UX design system skill.
  - Repository: https://github.com/dominikmartn/nothing-design-skill
  - Adapted as `.agents/tools/ui/nothing-design-skill/`

### Colour, Typography & Palette Tools

- **Colormind** -- AI-powered colour palette generator using deep learning trained on photographs, film, and art.
  - Website: http://colormind.io/
  - Bootstrap preview: http://colormind.io/bootstrap/
  - Dashboard preview: http://colormind.io/template/paper-dashboard/
  - API wrapper: `.agents/scripts/colormind-helper.sh`

- **Huemint** -- AI colour palette generator for brand identity, logos, and web mockups.
  - Website: https://huemint.com/

- **Fontjoy** -- AI font pairing generator using deep learning to find harmonious heading + body + accent combinations.
  - Website: https://fontjoy.com/

- **Poolors** -- Discover unique colour combinations that stand out from the crowd.
  - Website: https://poolors.com/

## UI & Frontend

### UI Skills

- **ui-skills.com** -- Opinionated constraints for building better interfaces with AI agents.
  - Website: https://www.ui-skills.com/
  - LLM rules: https://www.ui-skills.com/llms.txt
  - Adapted as `.agents/tools/ui/ui-skills.md`

### Component Libraries

- **shadcn/ui** -- Re-usable components built with Radix UI and Tailwind CSS.
  - Website: https://ui.shadcn.com/
  - Referenced in `.agents/tools/ui/shadcn.md`

## Agent & Prompt Engineering

### Upstream Prompt Base

- **anomalyco/Claude** -- The original system prompt template (`anthropic.txt @ 3c41e4e8f12b`) from which `build.txt` was derived.

## Design Inspiration Resources

See `.agents/tools/design/design-inspiration.md` for the full catalogue of 60+ curated UI/UX galleries, screenshot libraries, and pattern references.

## Video & Media

### HeyGen

- **HeyGen** -- AI avatar video creation API.
  - Website: https://heygen.com/
  - Referenced in `.agents/content/heygen-skill.md`

### Remotion

- **Remotion** -- Programmatic video creation with React.
  - Website: https://remotion.dev/
  - Referenced in `.agents/tools/video/` and skills

## Contributing

When ingesting external resources, tools, or design systems into aidevops, add a credit entry here with:

1. **Name** of the project or resource
2. **License** (if applicable)
3. **URL** to the source
4. **Location** of the adapted/referenced file within `.agents/`
5. **Brief description** of what was taken and how it's used
