---
description: Produce bounded offline marketing evidence reports and dry-run action proposals
agent: Marketing-Sales
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Marketing decisions

Target: $ARGUMENTS

1. Read `workflows/marketing-decisions.md`; collect offline evidence first with `marketing-snapshot-helper.py import`.
2. Validate or run supplied decisions with `marketing-decision-helper.py {validate|run}`. Cover matching, links, disposition, creative, community, and visibility; record unsupported collections rather than inventing coverage.
3. Render shared reporting with `marketing-decision-report-helper.py report --dry-run`. Preserve missing provider coverage and unknown economics.
4. Use `marketing-decision-jev-helper.py decide --dry-run` only for an optional, privacy/readiness-checked Jev route. Do not promise fallback or live readiness.
5. Render any local action as `marketing-action-helper.py plan --dry-run`; it is not approval and must not mutate accounts, providers, schedules, or publications.

Routine examples live in `templates/marketing-decision-routines.md` and are disabled until an operator explicitly configures and enables them.
