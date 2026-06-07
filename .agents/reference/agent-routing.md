<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agent Routing

## Core rule

Dispatch workers with `headless-runtime-helper.sh run`, not bare runtime CLIs. The helper provides provider rotation, session persistence, backoff, and lifecycle reinforcement. Bare `claude run`, `claude`, `claude -p`, or similar commands can skip lifecycle reinforcement and stop after PR creation (GH#5096).

## Routing order

1. Read the task or issue description.
2. If it is clearly code work (`implement`, `fix`, `refactor`, `CI`), use Build+ or omit `--agent`.
3. If trigger words clearly match another domain, pass `--agent <name>` or load the matching skill/subagent before acting.
4. If uncertain, default to Build+; it can load narrower docs on demand.
5. **Bundle-aware routing (t1364.6):** project bundles can define `agent_routing` overrides. Check with `bundle-helper.sh get agent_routing <repo-path>`. An explicit `--agent` flag wins.

The selected agent changes the system prompt and domain knowledge loaded for the worker.

## Primary agents

Full index: `subagent-index.toon`.

| Agent | Trigger words | Use for |
|-------|---------------|---------|
| Aidevops | aidevops, framework, setup, config, troubleshooting, MCP, agent, skill | Framework setup, configuration, troubleshooting, extension, releases |
| Build+ | implement, fix, refactor, bug, CI, tests, PR | Code: features, bug fixes, refactors, CI, PRs (default) |
| Automate | schedule, cron, dispatch, pulse, monitoring, routine | Scheduling, dispatch, monitoring, background orchestration, pulse supervisor |
| SEO | SEO, ranking, keyword, schema, GSC, sitemap, backlinks | SEO audits, keyword research, GSC, schema markup |
| Content | blog, video, script, social, newsletter, audio, image | Media production and distribution: blog, video, audio, image, social, newsletters, AI video generation |
| Marketing-Sales | ads, CRO, email campaign, CRM, copy, outreach, funnel | Email campaigns, FluentCRM, Meta Ads, CRO, direct response copy, CRM pipeline, proposals, outreach |
| Product | product, PRD, roadmap, validation, onboarding, monetisation, growth, analytics, UX | Product management, requirements, validation, onboarding, monetisation, growth, UI/UX, analytics |
| Business | company ops, finance, invoice, receipts, strategy, runners | Company operations, financial ops, invoicing, receipts, runner configs, strategy |
| Legal | legal, compliance, privacy policy, terms, contract, GDPR | Compliance, terms of service, privacy policy |
| Research | research, compare, market, competitor, technical analysis | Tech research, competitive analysis, market research |
| Health | health, wellness, nutrition, fitness, medical lifestyle | Health and wellness content |

For narrower domains such as Reports, WordPress, Shopify, Cloudflare, Proxmox, Remotion, CalDAV, or browser/mobile work, read `reference/domain-index.md` and the relevant skill/subagent entry before defaulting to Build+. For repeatable browser operations or web data mining, route through `/auto-browse` and `.agents/workflows/auto-browse.md` so profile state, safety gates, and private/shareable artifact boundaries are handled consistently.

For writing-quality requests such as humanise, tone, voice, writing style, less AI writing, make this sound natural, or match my style, read `content/humanise.md` before drafting or editing copy. This applies even when the primary task is README/docs, marketing copy, reports, or issue/PR text.

## Report routing

Use `agent:Reports` and `reports/general.md` when the task asks for a report, client audit, evidence-led PDF, scorecard, board pack, report preview, source ledger, or recurring report agent. Keep domain collection with the relevant primary/domain agent, then hand the evidence bundle to Reports for structure, citations, recommendations, and export contracts.

For new report agents, read `reports/routine-handoff.md` and `tools/build-agent/build-agent.md`: deterministic collection goes in `run:` steps; `agent:Reports` handles interpretation and narrative; `/report-render` or `scripts/commands/report-render.md` creates derived HTML/PDF previews from canonical `report.md` or `report.json`.

## Dispatch example

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
AGENTS_DIR="${AGENTS_DIR:-"$HOME/.aidevops/agents"}"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"
# Path is determined by 'paths.agents_dir' in config.jsonc

# Code task (default — Build+ implied)
$HELPER run \
  --role worker \
  --session-key "issue-42" \
  --dir ~/Git/myproject \
  --title "Issue #42: Fix auth" \
  --prompt "/full-loop Implement issue #42 -- Fix authentication bug" &
sleep 2

# SEO task
$HELPER run \
  --role worker \
  --session-key "issue-55" \
  --agent SEO \
  --dir ~/Git/myproject \
  --title "Issue #55: SEO audit" \
  --prompt "/full-loop Implement issue #55 -- Run SEO audit on landing pages" &
sleep 2

# Content task
$HELPER run \
  --role worker \
  --session-key "issue-60" \
  --agent Content \
  --dir ~/Git/myproject \
  --title "Issue #60: Blog post" \
  --prompt "/full-loop Implement issue #60 -- Write launch announcement blog post" &
sleep 2
```
