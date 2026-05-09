---
description: Auto-browse — learn, optimize, and graduate browser operations or web data-mining workflows
agent: Build+
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run the auto-browse workflow for authorized browser operations and web data mining.

Arguments: $ARGUMENTS

Read `.agents/workflows/auto-browse.md`, then execute that workflow with the supplied arguments.

## Invocation Patterns

| Pattern | Example | Behaviour |
|---------|---------|-----------|
| Concrete task | `/auto-browse "download invoices from the billing portal"` | Infer scope, ask only materially blocking questions, then plan or run |
| Bare intake | `/auto-browse` | Start a guided intake conversation before browsing or writing private state |
| Private workflow review | `/auto-browse --review ~/.aidevops/.agent-workspace/auto-browse/<id>` | Inspect an existing private run folder and recommend next action |
| Shareable plan | `/auto-browse --plan "create a reusable directory lead exporter"` | Produce a sanitized `todo/auto-browse/...` plan, not a private account workflow |

## Non-negotiables

- Do not browse, log in, create profiles, or touch private browser state until the workflow has target, authorization, allowed actions, and safety policy.
- Store account/site/client-specific workflows, cookies, storage state, downloads, and generated private agents under private aidevops user data, not repo `todo/`.
- Store only sanitized generalized briefs and implementation plans in `todo/`.
- Require explicit final confirmation for account creation, posting/messaging, payments/checkouts, destructive/admin actions, anti-detect/proxy/VPN use, and expanded personal/private data extraction.

## Related

- `.agents/workflows/auto-browse.md` — canonical workflow
- `.agents/tools/browser/auto-browse.md` — tool-routing and subagent design
- `.agents/tools/browser/browser-automation.md` — browser tool selection matrix
