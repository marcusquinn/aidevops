---
description: Validate Schema.org structured data (JSON-LD, Microdata, RDFa) against Schema.org specs and Google Rich Results requirements
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# Schema Validator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate structured data against Schema.org and Google Rich Results
- **Helper**: `~/.aidevops/agents/scripts/schema-validator-helper.sh`
- **Formats**: JSON-LD, Microdata, RDFa
- **Dependencies**: `@adobe/structured-data-validator`, `@marbec/web-auto-extractor`
- **Install dir**: `~/.aidevops/tools/schema-validator/`
- **Schema cache**: 24-hour TTL at `~/.aidevops/tools/schema-validator/schemaorg-all-https.jsonld`

**Commands**:

```bash
# Validate a URL
schema-validator-helper.sh validate "https://example.com"

# Validate a local HTML file
schema-validator-helper.sh validate "path/to/file.html"

# Validate raw JSON-LD content
schema-validator-helper.sh validate-json "path/to/data.json"

# Check installation status
schema-validator-helper.sh status

# Show help
schema-validator-helper.sh help
```

<!-- AI-CONTEXT-END -->

## Common Schema Types

| Type | Use Case |
|------|----------|
| `Article` | Blog posts, news articles |
| `Product` | E-commerce product pages |
| `FAQ` | Frequently asked questions |
| `HowTo` | Step-by-step guides |
| `Organization` | Company info |
| `LocalBusiness` | Local business listings |
| `BreadcrumbList` | Navigation breadcrumbs |
| `WebSite` | Sitelinks search box |

## SEO Audit Integration

Use during the **Technical SEO Audit** phase (`seo-audit-skill.md` → "Tools Referenced > Free Tools > Schema Validator").

**Complementary tools**: `seo/schema-markup.md` (templates, t092) · `seo/seo-audit-skill.md` (full audit) · Google Rich Results Test (t084)

## Troubleshooting

**"Cannot find module" errors**: Run `schema-validator-helper.sh status` to check installation. Dependencies auto-install on first run.

**Schema fetch failures**: The validator caches `schemaorg-all-https.jsonld` for 24 hours. If the fetch fails, it falls back to the cached version. Delete the cache file to force a re-fetch.

**Node.js version**: Requires Node.js 18+ (for native `fetch`). Falls back to `node-fetch` for older versions.
