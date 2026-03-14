---
description: Canonical routing taxonomy — domain labels and model tier labels for task creation and dispatch
---

# Task Taxonomy: Domain and Model Tier Classification

Single source of truth for the two classification tables used at task creation time
(`/new-task`, `/save-todo`, `/define`) and consumed at dispatch time (`/pulse`).

When a domain or tier is added or changed, update **only this file**. Command files
reference it by pointer.

---

## Domain Routing Table

Maps task content to a specialist agent. Used by task creation commands to apply
GitHub labels and TODO tags, and by the pulse to select the `--agent` flag at
dispatch time.

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

**Rule:** Omit the domain tag for code tasks — Build+ is the default and needs no
label. Only add a domain tag when the task clearly maps to a specialist domain.

---

## Model Tier Table

Maps task reasoning complexity to a model tier. Used by task creation commands to
apply `tier:` GitHub labels and TODO tags, and by the pulse to resolve the
`--model` flag at dispatch time via `model-availability-helper.sh resolve <tier>`.

| Tier | TODO Tag | GitHub Label | When to Apply |
|------|----------|--------------|---------------|
| thinking | `tier:thinking` | `tier:thinking` | Architecture decisions, novel design with no existing patterns, complex multi-system trade-offs, security audits requiring deep reasoning |
| simple | `tier:simple` | `tier:simple` | Docs-only changes, simple renames, formatting, config tweaks, label/tag updates |
| *(coding)* | *(none)* | *(none)* | Standard implementation, bug fixes, refactors, tests — **default, no label needed** |

**Rule:** Default to no tier label — most tasks are coding tasks that use sonnet.
Only add a tier label when the task clearly needs more reasoning power (`thinking`)
or clearly needs less (`simple`). When uncertain, omit.

---

## Usage by Command Files

- **`/new-task`** — classify after brief creation (Step 6.5); apply labels via `gh issue edit`
- **`/save-todo`** — classify during dispatch tag evaluation (Step 1b)
- **`/define`** — classify during task type detection (Step 1)
- **`/pulse`** — consume labels at dispatch time (Agent routing + Model tier selection sections)

See `scripts/commands/pulse.md` "Agent routing from labels" and "Model tier selection"
for how these labels are consumed at dispatch time.
