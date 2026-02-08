---
description: Write SEO-optimized long-form content with keyword integration
agent: Build+
mode: subagent
---

Write an SEO-optimized article on the given topic.

Topic/Keyword: $ARGUMENTS

## Workflow

1. **Research**: Determine search intent for the target keyword

   ```bash
   python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py intent "$ARGUMENTS"
   ```

2. **Context**: Check for project context files

   ```bash
   ls context/brand-voice.md context/style-guide.md context/internal-links-map.md context/target-keywords.md 2>/dev/null
   ls .aidevops/context/brand-voice.md .aidevops/context/style-guide.md 2>/dev/null
   ```

   If context files exist, read them before writing.

3. **Write**: Follow `content/seo-writer.md` guidelines to create the article:
   - 2,000-3,000+ words
   - Primary keyword in H1, first 100 words, 2-3 H2s
   - 1-2% keyword density
   - 3-5 internal links, 2-3 external links
   - Meta title (50-60 chars) and description (150-160 chars)
   - Grade 8-10 reading level

4. **Analyze**: Run content analysis on the draft

   ```bash
   python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze draft.md \
     --keyword "primary keyword" --secondary "kw1,kw2"
   ```

5. **Fix**: Address any critical issues from the analysis

6. **Output**: Save to `drafts/[topic]-[date].md` or current directory

## Related

- `content/seo-writer.md` - Writing guidelines
- `content/humanise.md` - Remove AI patterns after writing
- `seo/content-analyzer.md` - Analysis details
