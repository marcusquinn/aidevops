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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Schema Validator

- **Helper**: `schema-validator-helper.sh`
- **Formats**: JSON-LD, Microdata, RDFa
- **Dependencies**: `@adobe/structured-data-validator`, `@marbec/web-auto-extractor`
- **Install dir**: `~/.aidevops/tools/schema-validator/`
- **Schema cache**: 24-hour TTL (`schemaorg-all-https.jsonld`)

```bash
schema-validator-helper.sh validate "https://example.com"   # URL
schema-validator-helper.sh validate "path/to/file.html"     # local HTML
schema-validator-helper.sh validate-json "path/to/data.json" # raw JSON-LD
schema-validator-helper.sh status                            # check install
```

## Common Schema Types

| Type | Use Case |
|------|----------|
| `Article` | Blog posts, news |
| `Product` | E-commerce |
| `FAQ` | Frequently asked questions |
| `HowTo` | Step-by-step guides |
| `Organization` | Company info |
| `LocalBusiness` | Local listings |
| `BreadcrumbList` | Navigation |
| `WebSite` | Sitelinks search box |

## SEO Audit Integration

Use during Technical SEO Audit (`seo-audit-skill.md` → "Tools Referenced > Free Tools > Schema Validator").

Complementary: `seo/schema-markup.md` (templates, t092) · `seo/seo-audit-skill.md` · Google Rich Results Test (t084) · `seo/video-schema.md` (VideoObject + Clip validation)

## Troubleshooting

- **"Cannot find module"**: Run `schema-validator-helper.sh status`. Dependencies auto-install on first run.
- **Schema fetch failures**: Cached 24h; falls back to cache on failure. Delete cache file to force re-fetch.
- **Node.js version**: Requires Node.js 18+ (native `fetch`). Falls back to `node-fetch` for older versions.
