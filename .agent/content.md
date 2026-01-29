---
name: content
description: Content creation and management - copywriting, guidelines, editorial workflows
mode: subagent
subagents:
  # Content
  - guidelines
  - humanise
  - summarize
  # SEO integration
  - keyword-research
  - eeat-score
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
- `guidelines.md` - Content standards and style guide
- `humanise.md` - Remove AI writing patterns, make text sound human

**Integrations**:
- `seo.md` - Keyword optimization
- `tools/wordpress/` - Publishing workflow
- `tools/context/` - Research tools

**Workflow**:
1. Research (keywords, competitors, audience)
2. Outline (structure, key points)
3. Draft (following guidelines)
4. Optimize (SEO, readability)
5. Publish (via WordPress or CMS)

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

## Oh-My-OpenCode Integration

When oh-my-opencode is installed, leverage these specialized agents for enhanced content creation:

| OmO Agent | When to Use | Example |
|-----------|-------------|---------|
| `@document-writer` | Technical writing, documentation, long-form content | "Ask @document-writer to create a comprehensive guide on [topic]" |
| `@librarian` | Research best practices, find reference materials | "Ask @librarian for content structure examples" |
| `@multimodal-looker` | Analyze visual content, infographics, competitor layouts | "Ask @multimodal-looker to describe this infographic for alt text" |

**Enhanced Content Workflow**:

```text
1. Research → @librarian finds examples and best practices
2. Outline → Content agent structures the piece
3. Draft → @document-writer creates polished prose
4. Humanise → /humanise removes AI patterns, adds voice
5. Optimize → SEO agent adds keywords, meta
6. Visual → @multimodal-looker analyzes/describes images
7. Publish → WordPress agent deploys
```

**Note**: These agents require [oh-my-opencode](https://github.com/code-yeongyu/oh-my-opencode) plugin.
See `tools/opencode/oh-my-opencode.md` for installation.
