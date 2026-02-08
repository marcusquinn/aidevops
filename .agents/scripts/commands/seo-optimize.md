---
description: Run SEO optimization analysis on content and apply improvements
agent: Build+
mode: subagent
---

Optimize content for SEO performance.

Target: $ARGUMENTS

## Workflow

1. **Identify target**: Parse $ARGUMENTS for file path and optional keyword

2. **Run analysis**:

   ```bash
   python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze "$FILE" \
     --keyword "$KEYWORD" --secondary "$SECONDARY"
   ```

3. **Review results**: Check each category:
   - Readability score and grade
   - Keyword density and placement
   - SEO quality score (target 80+)
   - Critical issues (must fix)
   - Warnings (should fix)
   - Suggestions (nice to have)

4. **Apply fixes** in priority order:
   - Critical: Missing H1 keyword, no meta elements, content too short
   - High: Low keyword density, missing internal links
   - Medium: Reading level, paragraph length
   - Low: External links, transition words

5. **Re-analyze**: Run analysis again to verify improvements

6. **Generate report**: Summarize changes made and final scores

## Quick Commands

```bash
# SEO quality check
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md \
  --keyword "keyword" --meta-title "Title" --meta-desc "Description"

# Readability check
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md

# Keyword analysis
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md \
  --keyword "keyword" --secondary "kw1,kw2"
```

## Related

- `seo/seo-optimizer.md` - Full optimization checklist
- `seo/content-analyzer.md` - Analysis module details
- `content/meta-creator.md` - Meta element generation
- `content/internal-linker.md` - Internal linking strategy
