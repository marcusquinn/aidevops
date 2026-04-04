---
description: Canonical routing taxonomy — domain labels and model tier labels for task creation and dispatch
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Taxonomy: Domain and Model Tier Classification

Canonical source for `/new-task`, `/save-todo`, `/define`, and `/pulse`. When a domain or tier changes, update **only this file** — command docs point here, not duplicate the tables.

## Domain Routing Table

Apply a domain tag only when the task clearly belongs to a specialist agent. Code work stays unlabeled and routes to Build+.

| Domain Signal | TODO Tag | GitHub Label | Agent |
|--------------|----------|--------------|-------|
| SEO audit, keywords, GSC, schema markup, rankings | `#seo` | `seo` | SEO |
| Blog posts, articles, newsletters, video scripts, social copy | `#content` | `content` | Content |
| Email campaigns, FluentCRM, landing pages | `#marketing` | `marketing` | Marketing |
| Invoicing, receipts, financial ops, bookkeeping | `#accounts` | `accounts` | Accounts |
| Compliance, terms of service, privacy policy, GDPR | `#legal` | `legal` | Legal |
| Tech research, competitive analysis, market research, spikes | `#research` | `research` | Research |
| CRM pipeline, proposals, outreach | `#sales` | `sales` | Sales |
| Social media scheduling, posting, engagement | `#social-media` | `social-media` | Social-Media |
| Video generation, editing, animation, prompts | `#video` | `video` | Video |
| Health and wellness content, nutrition | `#health` | `health` | Health |
| Code: features, bug fixes, refactors, CI, tests | *(none)* | *(none)* | Build+ (default) |

**Rule:** Omit the domain tag for code tasks. Build+ is the default.

## Model Tier Table

Apply a tier tag only when the task needs more or less reasoning than the default (sonnet). `/pulse` resolves labels via `model-availability-helper.sh resolve <tier>`.

| Tier | TODO Tag | GitHub Label | When to Apply |
|------|----------|--------------|---------------|
| thinking | `tier:thinking` | `tier:thinking` | Architecture decisions, novel design with no existing patterns, complex multi-system trade-offs, security audits requiring deep reasoning |
| simple | `tier:simple` | `tier:simple` | Docs-only changes, simple renames, formatting, config tweaks, label/tag updates |
| *(coding)* | *(none)* | *(none)* | Standard implementation, bug fixes, refactors, tests — **default, no label needed** |

**Rule:** Default to no tier label. Use `thinking` for deeper reasoning, `simple` for lighter work, omit when uncertain.

## Command Use

- `/new-task` — classify after brief creation; apply labels via `gh issue edit`
- `/save-todo` — classify during dispatch tag evaluation
- `/define` — classify during task type detection
- `/pulse` — consume labels for agent routing and model tier selection

See `scripts/commands/pulse.md` "Agent routing from labels" and "Model tier selection" for dispatch behaviour.
