---
name: content
description: Content creation and management - copywriting, guidelines, editorial workflows
mode: subagent
subagents:
  # Content creation
  - guidelines
  - platform-personas
  - humanise
  - summarize
  - seo-writer
  - meta-creator
  - editor
  - internal-linker
  - context-templates
  - content-calendar
  # SEO integration
  - keyword-research
  - eeat-score
  - content-analyzer
  # WordPress publishing
  - wp-admin
  - mainwp
  # Research
  - context7
  - crawl4ai
  # Built-in
  - general
  - explore
---

# Content - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Content creation workflows
- **Focus**: Quality, SEO-optimized content production

**Subagents** (`content/`):

| Subagent | Purpose |
|----------|---------|
| `guidelines.md` | Content standards and style guide |
| `platform-personas.md` | Platform-specific voice adaptations (LinkedIn, Instagram, YouTube, X, Facebook) |
| `humanise.md` | Remove AI writing patterns, make text sound human |
| `seo-writer.md` | SEO-optimized content writing with keyword integration |
| `meta-creator.md` | Generate meta titles and descriptions for SEO |
| `editor.md` | Transform AI content into human-sounding articles |
| `internal-linker.md` | Strategic internal linking recommendations |
| `context-templates.md` | Per-project SEO context templates (brand voice, style, keywords) |
| `content-calendar.md` | Content calendar planning with gap analysis and lifecycle tracking |

**SEO Analysis** (via `seo/`):

| Subagent | Purpose |
|----------|---------|
| `content-analyzer.md` | Full content audit (readability, keywords, SEO quality) |
| `seo-optimizer.md` | On-page SEO recommendations |
| `keyword-mapper.md` | Keyword placement and density analysis |

**Integrations**:
- `seo.md` - Keyword research and optimization
- `tools/wordpress/` - Publishing workflow
- `tools/context/` - Research tools

**Content Analysis Script**:

```bash
# Full content analysis with keyword
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze article.md --keyword "target keyword"

# Individual analyses
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md --keyword "keyword"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py intent "search query"
```

**Workflow**:
1. Plan (`tools/content/content-calendar.md` for gap analysis and scheduling)
2. Research (keywords, competitors, audience)
3. Write (`content/seo-writer.md` with keyword targets)
4. Analyze (`seo-content-analyzer.py analyze`)
5. Optimize (address issues from analysis)
6. Edit (`content/editor.md` for human voice)
7. Publish (via WordPress or CMS)

<!-- AI-CONTEXT-END -->

## Content Creation Workflow

### Research Phase

Use context tools for research:
- `tools/context/context7.md` - Documentation lookup
- `tools/browser/crawl4ai.md` - Competitor analysis
- `seo/google-search-console.md` - Performance data

### Content Standards

See `content/guidelines.md` for:
- Voice and tone
- Formatting standards
- SEO requirements
- Quality checklist

See `content/platform-personas.md` for platform-specific adaptations:
- LinkedIn, Instagram, YouTube, X, Facebook voice guidelines
- Structure and length per platform
- Cross-platform content repurposing

### Humanising Content

Use `/humanise` or `content/humanise.md` to remove AI writing patterns:
- Inflated significance and promotional language
- Vague attributions and weasel words
- AI vocabulary (delve, tapestry, landscape, etc.)
- Rule of three, negative parallelisms
- Em dash overuse, excessive hedging

The humanise subagent is adapted from [blader/humanizer](https://github.com/blader/humanizer), based on Wikipedia's "Signs of AI writing" guide.

### Publishing

Integrate with WordPress workflow:
- Draft in preferred format
- Optimize for target keywords
- Publish via MainWP or direct

### Content Types

- Blog posts and articles
- Landing pages
- Product descriptions
- Technical documentation
- Marketing copy
