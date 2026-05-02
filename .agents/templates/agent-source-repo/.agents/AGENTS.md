<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

<!-- aidevops:agent-source-template:start -->
<!-- aidevops:agent-source-template-version: 1 -->

# Agent Pack Workspace

## Quick Reference

- Primary agents live at `.agents/<agent>.md`.
- Extended context for a primary agent lives at `.agents/<agent>/`.
- Shared capabilities live in `tools/`, `services/`, `workflows/`, `reference/`, `scripts/`, `configs/`, `templates/`, `rules/`, and `tests/`.
- Keep helper scripts flat in `scripts/`; prefer prefix naming over nested folders.
- Keep private identifiers out of public issue, PR, TODO, and log text.

## Placement Test

If another agent could use the knowledge independently, put it in a shared directory. If it only helps one primary agent decide what to do, put it beside that agent.

<!-- aidevops:agent-source-template:end -->
