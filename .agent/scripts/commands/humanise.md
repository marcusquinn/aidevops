---
description: Remove AI writing patterns from text to make it sound more natural and human
agent: Build+
mode: subagent
---

Remove signs of AI-generated writing from text, making it sound more natural and human-written.

Text to humanise: $ARGUMENTS

## Quick Reference

- **Purpose**: Remove AI writing patterns, add human voice
- **Source**: Adapted from [blader/humanizer](https://github.com/blader/humanizer)
- **Based on**: Wikipedia's "Signs of AI writing" guide

## Process

1. **Read the humanise subagent**: `content/humanise.md`
2. **Identify AI patterns** in the provided text
3. **Rewrite problematic sections** with natural alternatives
4. **Add voice and personality** - don't just remove patterns
5. **Present the humanised version** with optional change summary

## Usage

```text
/humanise [paste text here]

/humanise The new software update serves as a testament to the company's commitment to innovation.
```

Or provide a file path:

```text
/humanise path/to/content.md
```

## Key Patterns to Fix

From `content/humanise.md`:

**Content patterns:**
- Inflated significance ("pivotal moment", "testament to")
- Promotional language ("nestled", "vibrant", "breathtaking")
- Vague attributions ("experts believe", "industry reports")
- Superficial -ing analyses ("highlighting", "showcasing")

**Language patterns:**
- AI vocabulary (delve, tapestry, landscape, pivotal, crucial)
- Copula avoidance ("serves as" instead of "is")
- Rule of three overuse
- Synonym cycling

**Style patterns:**
- Em dash overuse
- Excessive boldface
- Title Case In Headings
- Emojis in professional content

**Communication patterns:**
- Chatbot artifacts ("I hope this helps!")
- Sycophantic tone ("Great question!")
- Knowledge-cutoff disclaimers

## Output Format

```text
Humanised Text
==============

[The rewritten text]

---

Changes made:
- Removed "serves as a testament" (inflated symbolism)
- Replaced "Moreover" with natural transition
- Simplified rule of three to specific details
- Added concrete examples instead of vague claims
```

## Integration with Content Workflow

The humanise command fits into the content creation workflow:

```text
1. Draft content
2. /humanise [content]  <- You are here
3. /linters-local (if code/markdown)
4. Publish
```

## Checking for Updates

The humanise subagent tracks upstream changes:

```bash
# Check for updates to the source skill
~/.aidevops/agents/scripts/humanise-update-helper.sh check
```
