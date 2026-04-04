---
description: Run SEO optimization analysis on content and apply improvements
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Target: $ARGUMENTS (file path + optional keyword)

## Workflow

1. **Analyze** — run `analyze` command (see Commands below). Target score: 80+.
2. **Review results** — SEO quality score, readability grade, keyword density, critical issues, warnings, suggestions.
3. **Apply fixes** in priority order:
   - Critical: Missing H1 keyword, no meta elements, content too short
   - High: Low keyword density, missing internal links
   - Medium: Reading level, paragraph length
   - Low: External links, transition words
4. **Re-analyze and report** — verify improvements, summarize changes and final scores.

## Commands

```bash
# Full analysis
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze "$FILE" --keyword "$KW"

# Quality check
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md \
  --keyword "keyword" --meta-title "Title" --meta-desc "Description"

# Readability
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md

# Keyword density
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md \
  --keyword "keyword" --secondary "kw1,kw2"
```

## Related

- `seo/seo-optimizer.md` - Full optimization checklist
- `seo/content-analyzer.md` - Analysis module details
- `content/meta-creator.md` - Meta element generation
- `content/internal-linker.md` - Internal linking strategy
