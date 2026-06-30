---
description: Pulse and worker utilisation diagnostics across repos.json, with self-improvement recommendations
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run a bounded pulse/worker productivity check for interactive sessions.

Arguments: $ARGUMENTS

## Goal

Answer “is the pulse using available concurrency and model/provider allowance?”
from canonical current-state evidence, not process snapshots or log mtimes.

## Procedure

1. Run the deterministic helper first:

   ```bash
   ~/.aidevops/agents/scripts/pulse-check-helper.sh report $ARGUMENTS
   ```

2. If the user asks for machine-readable evidence:

   ```bash
   ~/.aidevops/agents/scripts/pulse-check-helper.sh json $ARGUMENTS
   ```

3. If the user explicitly asks to file self-improvement work, or this is the
   scheduled daily routine, use deduplicated apply mode:

   ```bash
   ~/.aidevops/agents/scripts/pulse-check-helper.sh apply $ARGUMENTS
   ```

## Interpretation

- Prioritise 5–15 minute current-state evidence for “is work happening now?”
  claims.
- Use 24h/48h aggregates only for trend context and failure-family clustering.
- An issue is worth filing only when the helper marks a finding `autofile=true`
  or you can cite equivalent evidence from the helper JSON.
- Do not publish private repo names, local paths, issue titles, or raw worker
  examples in public comments/issues; the helper output is aggregate by design.

## Verification references

- `.agents/reference/diagnostics-discipline.md`
- `.agents/reference/worker-diagnostics.md`
- `.agents/scripts/tests/test-pulse-check-helper.sh`
