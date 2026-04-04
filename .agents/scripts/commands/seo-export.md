---
description: Export SEO data from multiple platforms to TOON format
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Export SEO ranking data from configured platforms to a common TOON format for analysis.

Target: $ARGUMENTS

## Usage

```bash
/seo-export all example.com
/seo-export gsc example.com
/seo-export bing example.com
/seo-export ahrefs example.com
/seo-export dataforseo example.com
/seo-export all example.com --days 30
/seo-export list
/seo-export exports example.com
```

Output: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`

## Process

1. Parse `$ARGUMENTS` for platform, domain, and options
2. Run: `~/.aidevops/agents/scripts/seo-export-helper.sh $ARGUMENTS`
3. Report: rows exported, output file path, errors/warnings

## Platform Requirements

| Platform | Credential | Env var |
|----------|------------|---------|
| GSC | Service account JSON | `GOOGLE_APPLICATION_CREDENTIALS` |
| Bing | API key | `BING_WEBMASTER_API_KEY` |
| Ahrefs | API key | `AHREFS_API_KEY` |
| DataForSEO | Username/password | `DATAFORSEO_USERNAME`, `DATAFORSEO_PASSWORD` |

Credentials: `~/.config/aidevops/credentials.sh`

## Next Steps

Run `/seo-analyze example.com` after export. Full docs: `seo/data-export.md`.
