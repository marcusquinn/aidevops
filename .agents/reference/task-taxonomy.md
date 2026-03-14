# Task Taxonomy — Canonical Routing Reference

Authoritative source for domain-routing and model-tier classification tables.
Referenced by `scripts/commands/new-task.md`, `scripts/commands/save-todo.md`, and `scripts/commands/define.md`.

Update this file when adding domains or changing tier criteria. All three command files will reflect the change automatically.

---

## Domain Routing

Maps task signal words to the specialist agent that handles it at dispatch time.
Add the TODO tag and GitHub label to the task entry when the domain matches.
**Omit domain tags for code tasks** — Build+ is the default and needs no label.

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

---

## Model Tier

Maps task reasoning complexity to the worker intelligence level used at dispatch time.
**Default to no tier tag** — most tasks are coding tasks that use sonnet.
Only add a tier tag when the task clearly needs more reasoning power (thinking) or clearly needs less (simple).

| Tier | TODO Tag | GitHub Label | When to Apply |
|------|----------|--------------|---------------|
| thinking | `tier:thinking` | `tier:thinking` | Architecture decisions, novel design with no existing patterns, complex multi-system trade-offs, security audits requiring deep reasoning |
| simple | `tier:simple` | `tier:simple` | Docs-only changes, simple renames, formatting, config tweaks, label/tag updates |
| *(coding)* | *(none)* | *(none)* | Standard implementation, bug fixes, refactors, tests — **default, no tag needed** |

---

## Usage

In task creation commands, reference this file instead of maintaining inline copies:

```text
See `reference/task-taxonomy.md` for domain routing and model tier classification tables.
```

Apply labels to the GitHub issue when a task ref exists:

```bash
REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
if [[ -n "$task_ref" && -n "$REPO_SLUG" ]]; then
  ISSUE_NUM="${task_ref#GH#}"
  # Apply tier label (only for non-default tiers)
  if [[ -n "$tier_label" ]]; then
    gh label create "$tier_label" --repo "$REPO_SLUG" >/dev/null 2>&1 || true
    gh issue edit "$ISSUE_NUM" --repo "$REPO_SLUG" --add-label "$tier_label" >/dev/null 2>&1 || \
      echo "[task] WARN: failed to apply tier label '$tier_label' to ${task_ref}" >&2
  fi
  # Apply domain label (only for non-code domains)
  if [[ -n "$domain_label" ]]; then
    gh label create "$domain_label" --repo "$REPO_SLUG" >/dev/null 2>&1 || true
    gh issue edit "$ISSUE_NUM" --repo "$REPO_SLUG" --add-label "$domain_label" >/dev/null 2>&1 || \
      echo "[task] WARN: failed to apply domain label '$domain_label' to ${task_ref}" >&2
  fi
fi
```
