---
description: Screaming Frog SEO Spider CLI for site crawling and auditing
mode: subagent
tools:
  read: true
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Screaming Frog SEO Spider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Advanced site crawling and SEO auditing via CLI.
- **License**: Paid ($259/yr) for CLI; free tier is GUI-only (500 URL cap).
- **Command**: `screamingfrogseospider`
- **Setup**: Download from [screamingfrog.co.uk](https://www.screamingfrog.co.uk/seo-spider/).
- **macOS Alias**: `alias screamingfrogseospider="/Applications/Screaming\ Frog\ SEO\ Spider.app/Contents/MacOS/ScreamingFrogSEOSpiderLauncher"`

## Usage

```bash
screamingfrogseospider --crawl https://example.com --headless --output-folder ./reports
```

- **Load Config**: `--config profile.seospiderconfig` (save from GUI first).
- **Export Tabs**: `--export-tabs "Internal:All,Response Codes:All"`
- **Bulk Export**: `--bulk-export "All Inlinks"`
- **Save Crawl**: `--save-crawl` (creates `.seospider` file).

## AI DevOps Integration

- **Deep Audit**: Use when `site-crawler` is insufficient for technical SEO.
- **Validation**: Re-crawl specific paths to verify fixes.
- **Analysis**: Generate CSVs for processing by other agents.

<!-- AI-CONTEXT-END -->
