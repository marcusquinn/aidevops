---
description: Recurring report routines and custom client report agent handoff
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Routine Handoff

Use this doc when a finished report should become a repeatable routine, custom
client report agent, or both. Split deterministic collection/export from
interpretation: `run:` performs repeatable commands, while `agent:Reports`
interprets evidence and writes the report.

## Handoff Decision

| Need | Use |
|------|-----|
| Same command gathers metrics or exports files | `run:` routine step |
| Same report needs narrative interpretation | `agent:Reports` routine step |
| Client has stable domain-specific rules | Custom report agent |
| Findings become implementation work | Worker-ready issue or `/full-loop` task |

For client-custom research reports, keep collection and interpretation separate:
first collect live evidence with deterministic helpers or service exports, then
ask the relevant domain agent plus `agent:Reports` to reason over the evidence.
This lets the same report format produce one-off client deliverables and later
become a monitoring routine without re-inventing the research workflow.

## Routine Pattern

Use `run:` for deterministic collection and export. Use `agent:Reports` only
after inputs exist.

```yaml
name: monthly-client-report
schedule: monthly(first-monday@09:00)
steps:
  - run: custom/scripts/collect-client-metrics.sh --month previous
  - run: custom/scripts/export-client-report-assets.sh --month previous
  - agent: Reports
    prompt: >
      Create the monthly client report from _reports/drafts/client/latest/.
      Use reports/general.md, reports/citations.md, reports/exporters.md, and
      the client report agent rules. Return report.md plus handoff notes.
```

## Custom Client Report Agent Prompt Template

Use this template after a successful report when the format, evidence sources,
and interpretation rules should be reused.

```markdown
Create a custom client report agent and routine from the finished report.

Finished report:
- Canonical Markdown: `<path-to-report.md>`
- Evidence ledger: `<path-to-citations-or-ledger>`
- Export bundle: `<path-to-reviewed-export-bundle>`

Client context:
- Client/project: `<safe public name or placeholder>`
- Audience: `<decision makers>`
- Cadence: `<weekly/monthly/quarterly/ad hoc>`
- Confidentiality: `<public/internal/private>`
- Required exports: `<Markdown/HTML/PDF/DOCX/archive>`

Reuse rules:
- Preserve sections: `<list sections>`
- Preserve KPIs or scorecards: `<list metrics>`
- Preserve citation style: `reports/citations.md`
- Preserve exporter rules: `reports/exporters.md`
- Domain docs to route through: `<seo.md/marketing-sales.md/business.md/...>`
- Do not duplicate domain expertise in the custom agent.

Routine design:
- `run:` steps for deterministic collection/export: `<commands or scripts>`
- `agent:Reports` prompt for interpretation: `<prompt>`
- Verification: `<commands, lint, export preview, citation/privacy checks>`
- Output location: `_reports/drafts/<client>/<period>/report.md`

Deliverables:
1. Custom agent draft under the appropriate `custom/` or project path.
2. Routine YAML or setup command using `run:` before `agent:Reports`.
3. First dry-run checklist with expected inputs, outputs, and blockers.
```

## Handoff Checklist

- The finished report has source IDs, evidence ledger, and export notes.
- Client-custom reports list the live data sources used and the unavailable tools
  or credentials that limited analysis.
- Collection commands are deterministic and safe to run unattended.
- Secrets and client-specific credentials are referenced by secret name only.
- The routine writes to `_reports/drafts/` before any published bundle.
- The interpretation prompt names domain docs and shared report contracts.
- Verification includes Markdown lint, citation check, export preview, and privacy
  review appropriate to the report.

## Related

- `workflows/routine.md` -- operational routine setup.
- `reports/general.md` -- report anatomy and quality gate.
- `reports/citations.md` -- evidence ledger contract.
- `reports/exporters.md` -- export and dependency rules.
