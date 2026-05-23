<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Domain-Specific Authority Signals and Attribution

## Domain-Specific Authority Signals

| Domain | Key signals |
|--------|-------------|
| **Technology** | Technical precision, version numbers, dates, official docs, code examples |
| **Health/Medical** | Peer-reviewed studies, expert credentials (MD, RN), study limitations, "last reviewed" dates |
| **Financial** | Regulatory bodies (SEC, FTC), numbers with timeframes, "educational not advice" disclaimers |
| **Legal** | Specific laws/statutes, jurisdiction, professional disclaimers, "consult a professional" |
| **Business/Marketing** | Case studies with results, industry research, percentage changes, thought leader quotes |

## UTM Citation Attribution

Keep the canonical URL clean. Add tracking parameters only to cited variants.

```markdown
<!-- Canonical -->
https://yourdomain.com/product-features/
<!-- Cited variant -->
https://yourdomain.com/product-features/?utm_source=ai&utm_medium=citation&utm_campaign=[model-name]
```

Track citation traffic volume, citation-to-conversion rate, page citation distribution, and UTM coverage.

## Evidence Ledger Source IDs

Material SEO/GEO recommendations must cite source IDs so reports and workers can
trace each claim back to evidence.

| Source type | Example source ID | Required detail |
|-------------|-------------------|-----------------|
| Owned page section | `OWN-001` | URL/path, heading or selector, captured date, claim supported |
| Third-party profile | `TP-001` | Platform, profile URL, visible fact, captured date |
| Engine result | `ENG-001` | Engine, prompt/query, date, citations or mentions, observed gap |
| Research or report | `RES-001` | Method, sample, date range, limitation, reusable statistic |
| Policy or certification | `POL-001` | Issuer, scope, expiry or review date, claim supported |

Do not promote a finding to the roadmap unless the cited source IDs support the
recommendation. If evidence is weak, mark confidence low and add evidence
collection before content changes.

## Engine-Specific Attribution

- Track AIO, Gemini, ChatGPT, AI Mode, and Perplexity separately because they
  may mention a brand without citing it, cite a third party instead of the owned
  page, or omit the entity for different reasons.
- Do not aggregate AI Share of Voice without showing per-engine mention and
  citation lines first.
- Attach source IDs to each engine observation so citation movement can be
  re-tested after page or profile updates.
