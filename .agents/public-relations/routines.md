---
description: Recurring PR routine patterns for aidevops
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# PR Routines

Use `workflows/routine.md` to schedule recurring PR work. `TODO.md` remains the source of truth.

## Routine templates

```markdown
## Routines

- [ ] r-pr001 Daily newsjack scan repeat:daily(@08:00) ~20m agent:PR
- [ ] r-pr002 Daily coverage tracker repeat:daily(@09:00) ~10m agent:PR
- [ ] r-pr003 Weekly PR opportunity review repeat:weekly(mon@10:00) ~30m agent:PR
```

## SOP boundaries

- PR defines the evidence and judgment workflow.
- Automate schedules and dispatches the recurring prompt.
- Content turns approved PR angles into owned-channel assets.
- Marketing-Sales handles CRM/funnel follow-through after earned-media strategy, not journalist outreach automation.

## Safety

Never schedule journalist sends. Schedule monitoring, reports, drafts, and review queues only.
