---
description: Analyze existing content for SEO improvements and content health
agent: Build+
mode: subagent
---

Analyze existing content for SEO performance and improvement opportunities.

Target: $ARGUMENTS

## Workflow

1. **Identify target**: $ARGUMENTS can be a file path or URL

2. **If URL**: Fetch content first

   ```bash
   # Use webfetch tool to get the content
   # Save to a temporary file for analysis
   ```

3. **Run comprehensive analysis**:

   ```bash
   python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze "$FILE" \
     --keyword "$KEYWORD"
   ```

4. **Generate content health report**:
   - Overall SEO quality score (0-100)
   - Readability grade
   - Keyword optimization status
   - Structure assessment
   - Link analysis
   - Priority improvements

5. **Recommend action**:
   - Score 80+: Minor tweaks only
   - Score 60-79: Targeted optimization needed
   - Score below 60: Consider rewrite with `/seo-write`

## Related

- `seo/content-analyzer.md` - Analysis module details
- `seo/seo-optimizer.md` - Optimization checklist
- `content/seo-writer.md` - For rewrites
