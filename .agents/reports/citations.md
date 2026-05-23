---
description: Inline citation and citations.json contract for reports
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Citation Contract

Reports are only as useful as their evidence trail. Use stable source IDs in the
Markdown report and optionally mirror the ledger in `citations.json` for tools,
exporters, or client portals.

## Inline Citation Rules

- Assign each source a stable ID: `S001`, `S002`, `S003`.
- Cite material claims inline with source IDs, for example: `[S001]`.
- Put citations at the sentence or bullet where the claim appears.
- Use multiple IDs when a claim depends on multiple sources: `[S001, S004]`.
- Use evidence labels when helpful: `[S002 observed]`, `[S003 verified]`.
- If a claim is useful but not proven, label it `unsupported` and move it to a
  risk, assumption, or backlog section.
- Do not cite private local paths, private repository names, or secrets in public
  reports; use placeholders and keep raw source mapping private.

## Evidence Ledger Fields

Include a Markdown table in the report appendix when the report has material
recommendations:

| Field | Required | Notes |
|-------|----------|-------|
| `source_id` | Yes | Stable ID used inline, such as `S001`. |
| `type` | Yes | Tool output, URL, screenshot, export, file, metric, log, interview. |
| `title` | Yes | Human-readable source title. |
| `locator` | Yes | URL, file path placeholder, command, PR, issue, or dashboard name. |
| `captured_at` | Yes | ISO date or date-time. |
| `claim_supported` | Yes | What the source proves. |
| `confidence` | Yes | `observed`, `verified`, `inferred`, `unsupported`, or `benchmark`. |
| `freshness_risk` | No | Low, medium, high, or a review date. |
| `notes` | No | Caveats, filters, sample size, or access constraints. |

## Optional citations.json

Create `citations.json` beside `report.md` when an exporter, portal, or routine
needs machine-readable sources:

```json
{
  "version": 1,
  "report": "report.md",
  "sources": [
    {
      "source_id": "S001",
      "type": "tool_output",
      "title": "Crawl summary",
      "locator": "_reports/drafts/example/crawl-summary.json",
      "captured_at": "2026-05-23",
      "claim_supported": "The crawl found 12 missing meta descriptions.",
      "confidence": "observed",
      "freshness_risk": "medium",
      "notes": "Sanitized path for public bundle."
    }
  ]
}
```

## Validation Checklist

- Every `source_id` used inline appears in the evidence ledger.
- Every material recommendation cites at least one `observed` or `verified`
  source, or explicitly names the assumption being tested.
- Public reports contain no secrets, private basenames, private repo names, or
  machine-specific local paths.
- Derived HTML/PDF exports preserve citation labels and source visibility.

## Related

- `tools/design/report-presentation.md` -- evidence badges and source cards.
- `reports/exporters.md` -- export bundles must preserve citations.
- `reports/outputs.md` -- `_reports/` output directory contract.
