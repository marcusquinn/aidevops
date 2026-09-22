---
description: Local-first evidence-led prospecting with private storage and explicit operator activation
---

# Prospecting

Prospecting is a private, single-operator workflow for reviewing evidence-backed
lead candidates. It is not a scraper, outreach sender, hosted SaaS, or an
automatic schedule. Raw evidence remains in `_knowledge`; the local SQLite
projection stores only references, scoring explanations, and local dispositions.

## Start locally

Use a dedicated private directory and the supplied synthetic fixture before
connecting any provider:

```bash
python3 .agents/scripts/prospecting-project-helper.py --store "$HOME/.aidevops/prospecting" init --input PROJECT.json
python3 .agents/scripts/prospecting-service-helper.py --store "$HOME/.aidevops/prospecting" serve --ui-dir .agents/templates/prospecting-workbench
```

The service binds to `127.0.0.1` by default. `/ui/` is a local workbench and
`/v1` is the scoped REST contract in `configs/prospecting-openapi.json`.

## Workflow and boundaries

1. Import reviewed product evidence and create an explicit discovery plan.
2. Capture bounded posts/comments as `_knowledge` references, then score through
   the existing prospecting contracts. Review or hide leads locally; no message
   is sent.
3. Use `prospecting-seo-helper.py` and `prospecting-insights-helper.py` for
   observations, themes, and unknown coverage. Results are not ROI, conversion,
   or AI-citation claims.
4. Preview routines, usage, and digests with their `--dry-run` paths. Schedules,
   providers, alert delivery, and spending remain disabled until the operator
   explicitly configures and activates them.

Profiles and rescoring use versioned compare-and-swap edits; disposition history
survives rescoring. Read `reference/prospecting-contract.md` for transaction,
retention, restore, and provider boundaries.

## Routing

Use `/prospecting` for onboarding, scan, leads, Reddit SEO, insights, alerts,
usage, scoped API/MCP, or workbench guidance. Use `/marketing-decisions` for a
separate offline report/action-proposal handoff. Do not use AnyAPI, Lurk, or a
generic scraping platform as a fallback.

## Parity matrix

| Surface | Native behavior | Evidence / availability | Excluded |
|---|---|---|---|
| Evidence and scoring | Project-isolated SQLite projection, versioned scores and dispositions | Offline integration test | Raw social copying, automated contact |
| Search and themes | SERP observations and aggregate insights | Offline fixtures; live providers require readiness | Guaranteed rankings or citations |
| Service, REST, MCP, UI | Loopback API, scoped keys/sessions, local workbench | API and integration tests | Hosted auth/database by default |
| Routines and alerts | Disabled dry-run planning and digest preview | Routine tests | Auto-installed schedules or delivery |
| Container | Unprivileged loopback compose with persistent volume | Compose config validation | Image publication or public exposure |

Provider setup uses `aidevops secret set NAME` and capability readiness checks;
keep values out of profiles, logs, templates, and images. Costs, quotas, and
live-provider coverage are unknown until configured and observed.
