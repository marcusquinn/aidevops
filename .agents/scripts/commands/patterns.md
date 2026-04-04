---
description: Show cross-session success/failure patterns to guide task approach and model routing
agent: Build+
mode: subagent
model: haiku
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Query cross-session patterns from memory, filter to `$ARGUMENTS` if provided, and present:

- **What works:** approaches with repeated success in similar tasks
- **What fails:** approaches with repeated failure or regressions
- **Recommended tier:** best model tier with rationale from pattern evidence

**Mode** (from arguments): `recommend` → prioritize tier recommendation. `report` → full summary. Default → concise task-focused suggestions.

Query all pattern types:

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall "success pattern" --type SUCCESS_PATTERN --limit 20
~/.aidevops/agents/scripts/memory-helper.sh recall "failure pattern" --type FAILURE_PATTERN --limit 20
~/.aidevops/agents/scripts/memory-helper.sh recall "working solution" --type WORKING_SOLUTION --limit 10
~/.aidevops/agents/scripts/memory-helper.sh recall "failed approach" --type FAILED_APPROACH --limit 10
```

If no patterns exist, return:

```text
No patterns recorded yet. Patterns are recorded automatically by the pulse supervisor after observing outcomes, or manually with:

  /remember "SUCCESS: bugfix with sonnet — structured debugging found root cause quickly"
  /remember "FAILURE: architecture with sonnet — needed opus for cross-service trade-offs"

Available commands: /patterns suggest, /patterns recommend, /patterns report
```
