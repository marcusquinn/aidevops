---
description: Export SEO data from multiple platforms to TOON format
agent: SEO
mode: subagent
---

Export SEO ranking data from configured platforms to a common TOON format for analysis.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Export SEO data for analysis
- **Platforms**: GSC, Bing, Ahrefs, DataForSEO
- **Output**: `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`

## Usage

```bash
# Export from all platforms
/seo-export all example.com

# Export from specific platform
/seo-export gsc example.com
/seo-export bing example.com
/seo-export ahrefs example.com
/seo-export dataforseo example.com

# With date range
/seo-export all example.com --days 30

# List available platforms
/seo-export list

# List exports for a domain
/seo-export exports example.com
```

## Process

1. Parse $ARGUMENTS to extract platform, domain, and options
2. Run the appropriate export script:

```bash
~/.aidevops/agents/scripts/seo-export-helper.sh $ARGUMENTS
```

3. Report results including:
   - Number of rows exported
   - Output file location
   - Any errors or warnings

## Platform Requirements

| Platform | Credential | Location |
|----------|------------|----------|
| GSC | Service account JSON | `GOOGLE_APPLICATION_CREDENTIALS` |
| Bing | API key | `BING_WEBMASTER_API_KEY` |
| Ahrefs | API key | `AHREFS_API_KEY` |
| DataForSEO | Username/password | `DATAFORSEO_USERNAME`, `DATAFORSEO_PASSWORD` |

All credentials should be set in `~/.config/aidevops/credentials.sh`.

## Next Steps

After export, suggest running analysis:

```bash
/seo-analyze example.com
```

## Documentation

For full documentation, read `seo/data-export.md`.
