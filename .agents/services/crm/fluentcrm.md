---
description: FluentCRM MCP - WordPress CRM with email marketing, automation, and contact management via FluentCRM's native MCP server
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  fluentcrm-*: true
  fluentcrm_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# FluentCRM MCP Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: WordPress CRM plugin with a native MCP server and REST API
- **MCP endpoint**: `https://<site>/wp-json/fluent-crm/mcp` (on by default; needs the WordPress MCP Adapter on the site)
- **Auth**: WordPress user + Application Password, resolved at launch by `wordpress-mcp-helper.sh serve-http`
- **Helper preset**: `fluentcrm` → server `fluentcrm-<site>`
- **REST fallback**: `https://<site>/wp-json/fluent-crm/v2`
- **Shared setup, rules and fallback**: `tools/wordpress/fluent-mcp.md`

<!-- AI-CONTEXT-END -->

## Setup

```bash
aidevops secret set EXAMPLE_WP_APP_PASSWORD   # run in your own terminal
~/.aidevops/agents/scripts/wordpress-mcp-helper.sh plugin-mcp-check fluentcrm https://example.com aidevops-bot EXAMPLE_WP_APP_PASSWORD
~/.aidevops/agents/scripts/wordpress-mcp-helper.sh plugin-mcp-config fluentcrm example https://example.com aidevops-bot EXAMPLE_WP_APP_PASSWORD opencode
```

Merge the printed `mcp` object into `~/.config/opencode/opencode.json`, or run the printed `claude mcp add-json` command for Claude Code. Template: `configs/mcp-templates/fluentcrm.json`. Entries are disabled by default; enable per session or through this subagent (`fluentcrm-*` tools).

If `plugin-mcp-check` returns 404, follow the troubleshooting table in `tools/wordpress/fluent-mcp.md` (MCP Adapter missing, MCP disabled, plugin outdated).

## Tools

Observed on FluentCRM 3.2.5 (25 tools). Confirm the live list with `plugin-mcp-check` before relying on a name.

| Area | Tools | Access |
|------|-------|--------|
| Context | `fluent-crm-get-crm-context` | read |
| Contacts | `list-contacts`, `get-contact`, `get-contact-filter-schema` | read |
| Contacts | `upsert-contact`, `bulk-upsert-contacts`, `delete-contact`, `apply-segments-to-contacts` | write |
| Notes | `add-contact-note`, `delete-contact-note` | write |
| Tags and lists | `list-tags`, `list-lists` | read |
| Tags and lists | `manage-tag`, `manage-list` | write |
| Campaigns | `list-campaigns`, `get-campaign`, `render-email-preview` | read |
| Campaigns | `upsert-campaign` | write |
| Campaigns | `change-campaign-status` | **sends/pauses live campaigns** |
| Email | `send-test-email`, `send-email-to-contact` | **sends email** |
| Automations | `list-automations`, `get-automation`, `list-funnel-subscribers` | read |
| Automations | `update-contact-automation-status` | **changes live automation state** |

All names carry the `fluent-crm-` prefix. Tools marked in bold contact real people or change live sends: present the exact call and recipients, and run it only on an explicit request. Contact data is personal data; summarise rather than dump records.

## Common workflows

- **Segment review**: `get-crm-context` → `get-contact-filter-schema` → `list-contacts` with filters → report counts and samples.
- **Contact hygiene**: `get-contact` → propose tag/list changes → `apply-segments-to-contacts` or `upsert-contact` after approval → re-read to verify.
- **Campaign draft**: `list-campaigns` → `upsert-campaign` (draft) → `render-email-preview` → `send-test-email` to an internal address → hand back for approval before `change-campaign-status`.
- **Automation check**: `list-automations` → `get-automation` → `list-funnel-subscribers` to explain where contacts are.

## Legacy community server

Before FluentCRM shipped a native server, aidevops documented the community `netflyapp/fluentcrm-mcp-server` (local build, `fluentcrm_*` tools, credentials in `credentials.sh`). Prefer the native server: it needs no build, uses FluentCRM's own permission checks and keeps the password out of runtime config. Existing `fluentcrm_*` configurations keep working with this subagent until removed.

## Related

- `tools/wordpress/fluent-mcp.md` — all Fluent plugin MCP servers, operating rules, REST/WP-CLI fallback
- `marketing-sales.md` — Sales/marketing workflows, tag naming conventions, lead processing
- `services/email/ses.md` — Email delivery via SES
- FluentCRM Docs: <https://fluentcrm.com/docs/>
- FluentCRM REST API: <https://rest-api.fluentcrm.com/>
