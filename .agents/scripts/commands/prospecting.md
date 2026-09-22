---
description: Guide private, local-first prospecting without provider activation or outreach
agent: Marketing-Sales
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Prospecting

Target: $ARGUMENTS

1. Read `marketing-sales/prospecting.md` and `reference/prospecting-contract.md`.
2. Route onboarding, scan, leads, Reddit SEO, insights, alerts, usage, REST/MCP,
   or workbench requests to the matching `prospecting-*-helper.py` contract.
3. Start with synthetic/offline data and dry-run commands. Preserve unknown
   provider coverage, budgets, and evidence gaps; do not activate providers,
   schedules, alerts, spending, or outreach.
4. For REST/MCP, use `configs/prospecting-openapi.json` and scoped local keys;
   never edit global client configuration or connect an MCP automatically.
5. For local container operation, read `services/hosting/prospecting-self-host.md`.
