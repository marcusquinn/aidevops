---
name: context-templates
description: Context file templates for SEO content creation (brand voice, style guide, keywords, links)
mode: subagent
model: haiku
---

# Content Context Templates

Templates for project-level context files that guide SEO content creation. Adapted from [TheCraigHewitt/seomachine](https://github.com/TheCraigHewitt/seomachine) (MIT License).

## Setup

Create a `context/` directory in your project root and populate these templates:

```bash
mkdir -p context
```

The content writing subagents (`content/seo-writer.md`, `content/editor.md`, `content/internal-linker.md`) automatically check for these files before writing.

## Templates

### context/brand-voice.md

```markdown
# Brand Voice Guide

## Voice Pillars
- **[Pillar 1]**: [Description of this voice quality]
- **[Pillar 2]**: [Description]
- **[Pillar 3]**: [Description]

## Tone by Content Type
| Content Type | Tone | Example |
|-------------|------|---------|
| Blog posts | [e.g., conversational, expert] | "Here's what we found..." |
| Landing pages | [e.g., confident, direct] | "Get started in minutes" |
| Documentation | [e.g., clear, helpful] | "Follow these steps..." |

## Core Messages
1. [Primary value proposition]
2. [Secondary message]
3. [Differentiator]

## Writing Style
- **Sentence length**: [e.g., Mix of short and medium]
- **Vocabulary level**: [e.g., Professional but accessible]
- **Contractions**: [e.g., Yes, use naturally]
- **First person**: [e.g., "We" for company, avoid "I"]
- **Reader address**: [e.g., "You" directly]

## Words to Use
[List preferred terminology]

## Words to Avoid
[List terms that don't fit the brand]
```

### context/style-guide.md

```markdown
# Style Guide

## Grammar and Mechanics
- **Oxford comma**: [Yes/No]
- **Capitalization**: [Title case for headings / Sentence case]
- **Numbers**: [Spell out under 10 / Always use digits]
- **Dates**: [Format: January 15, 2026]

## Formatting
- **Headings**: [H2 for main sections, H3 for subsections]
- **Lists**: [Bullet for unordered, numbered for steps]
- **Bold**: [For key terms and emphasis]
- **Code**: [Backticks for technical terms]

## Terminology
| Use | Don't Use |
|-----|-----------|
| [preferred term] | [avoided term] |

## Content Structure
- Introduction: [Hook + context + promise]
- Body: [H2 sections every 300-400 words]
- Conclusion: [Summary + CTA]
```

### context/target-keywords.md

```markdown
# Target Keywords

## Pillar Topics

### [Topic Cluster 1]
- **Pillar keyword**: [main keyword] (volume: X, difficulty: Y)
- **Cluster keywords**:
  - [subtopic keyword 1] (volume: X)
  - [subtopic keyword 2] (volume: X)
  - [subtopic keyword 3] (volume: X)
- **Long-tail variations**:
  - [long-tail 1]
  - [long-tail 2]
- **Search intent**: [informational/commercial/transactional]

### [Topic Cluster 2]
...

## Current Rankings
| Keyword | Position | URL | Opportunity |
|---------|----------|-----|-------------|
| [keyword] | [pos] | [url] | [action needed] |
```

### context/internal-links-map.md

```markdown
# Internal Links Map

## Product/Feature Pages
- [/features](/features) - Main features overview (anchor: "our features")
- [/pricing](/pricing) - Pricing plans (anchor: "pricing", "plans")
- [/integrations](/integrations) - Integration directory

## Pillar Content
- [/blog/guide-to-X](/blog/guide-to-X) - Primary pillar (anchor: "complete guide to X")
- [/blog/Y-explained](/blog/Y-explained) - Secondary pillar (anchor: "understanding Y")

## Top Blog Posts
- [/blog/how-to-Z](/blog/how-to-Z) - High traffic (anchor: "how to Z")
- [/blog/best-tools](/blog/best-tools) - High conversion (anchor: "best tools for...")

## Topic Clusters
### Cluster: [Topic A]
- Pillar: /blog/topic-a-guide
- Cluster: /blog/topic-a-subtopic-1
- Cluster: /blog/topic-a-subtopic-2
```

### context/competitor-analysis.md

```markdown
# Competitor Analysis

## Primary Competitors
| Competitor | Domain | Strengths | Weaknesses |
|-----------|--------|-----------|------------|
| [Name] | [domain.com] | [what they do well] | [gaps we can exploit] |

## Content Strategy Comparison
| Topic | Us | Competitor A | Competitor B | Gap |
|-------|-----|-------------|-------------|-----|
| [topic] | [our coverage] | [their coverage] | [their coverage] | [opportunity] |

## Keyword Gaps
Keywords competitors rank for that we don't:
- [keyword] - [competitor] ranks #[X], we don't rank
```

### context/seo-guidelines.md

```markdown
# SEO Guidelines

## Content Requirements
- Minimum word count: 2,000 (optimal: 2,500-3,000)
- Primary keyword density: 1-2%
- Reading level: Grade 8-10

## On-Page SEO
- Meta title: 50-60 characters, keyword near front
- Meta description: 150-160 characters, include keyword and CTA
- H1: Single, includes primary keyword
- H2: 4+ sections, 2-3 include keyword variations
- Internal links: 3-5 per article
- External links: 2-3 to authoritative sources

## Technical
- URL slug: lowercase, hyphens, include keyword
- Image alt text: descriptive, include keyword variation
- Schema markup: Article, FAQ, HowTo as appropriate
```

## Usage

Content subagents check for these files automatically:

```bash
# Check what context is available
ls context/ 2>/dev/null || ls .aidevops/context/ 2>/dev/null

# Initialize context for a new project
mkdir -p context
# Then populate templates above with your project's information
```
