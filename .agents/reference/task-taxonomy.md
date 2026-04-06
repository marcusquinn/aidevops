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

Tiers route tasks to models with appropriate capability. The pulse resolves labels via `model-availability-helper.sh resolve <tier>`. Label every task — explicit tiers enable cascade dispatch (try cheap first, escalate with accumulated context).

| Tier | TODO Tag | GitHub Label | Model | When to Apply |
|------|----------|--------------|-------|---------------|
| simple | `tier:simple` | `tier:simple` | Haiku | Prescriptive brief with code blocks; single-file edits following existing patterns; config tweaks; docs-only changes |
| standard | `tier:standard` | `tier:standard` | Sonnet | Standard implementation, bug fixes, refactors, tests — needs judgment, error recovery, multi-file reasoning |
| reasoning | `tier:reasoning` | `tier:reasoning` | Opus | Architecture decisions, novel design with no existing patterns, complex multi-system trade-offs, security audits requiring deep reasoning |

**Rules:**
- Default to `tier:standard` when uncertain. Use `tier:simple` for prescriptive work, `tier:reasoning` for deep reasoning.
- **Cascade dispatch:** The pulse may start at `tier:simple` and escalate through `tier:standard` → `tier:reasoning` if the worker fails. Each tier's attempt produces a structured escalation report (see `templates/escalation-report-template.md`) that gives the next tier pre-digested context.
- **Backward compatibility:** `tier:thinking` is accepted as an alias for `tier:reasoning` during transition. Scripts match both labels.

## Cascade Dispatch Model

Instead of classifying tasks to the "correct" tier upfront, the cascade model starts cheap and escalates with knowledge:

```text
tier:simple (Haiku, 1x cost)
  ✓ Success → done (cheapest resolution)
  ✗ Failure → structured escalation report on issue → re-dispatch at tier:standard

tier:standard (Sonnet, 12x cost)
  ✓ Success → done (saved exploration tokens via escalation context)
  ✗ Failure → richer escalation report → re-dispatch at tier:reasoning

tier:reasoning (Opus, 60x cost)
  ✓ Success → done (had full diagnostic context from both prior attempts)
  ✗ Failure → human review with complete attempt history
```

Each escalation report captures: what was attempted, where it got stuck, what was unclear in the brief, and what was discovered. The next tier starts with this context instead of exploring from zero. See `templates/escalation-report-template.md` for the structured format.

### Escalation Reason Taxonomy

Structured reasons feed back into brief template optimisation:

| Reason | Meaning | Brief improvement |
|--------|---------|-------------------|
| `AMBIGUOUS_BRIEF` | Multiple valid interpretations | More specific code blocks |
| `STALE_REFERENCES` | File paths/lines don't match current state | Verify file state at dispatch time |
| `JUDGMENT_NEEDED` | Multiple valid approaches, can't choose | Specify pattern to follow |
| `MULTI_FILE_COORDINATION` | Non-obvious cross-file dependencies | Add dependency map to brief |
| `ERROR_RECOVERY` | Hit unexpected error, can't self-recover | Add fallback instructions |
| `TOOL_CHAIN_COMPLEXITY` | Too many sequential tool calls | Pre-compute intermediate state |
| `MISSING_CONTEXT` | Brief lacks background for the decision | Add "Context & Decisions" section |

## Command Use

- `/new-task` — classify after brief creation; apply labels via `gh issue edit`
- `/save-todo` — classify during dispatch tag evaluation
- `/define` — classify during task type detection
- `/pulse` — consume labels for agent routing, model tier selection, and cascade dispatch

See `scripts/commands/pulse.md` "Agent routing from labels" and "Model tier selection" for dispatch behaviour.
