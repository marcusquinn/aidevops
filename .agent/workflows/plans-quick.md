---
description: Quick task recording to TODO.md without full PRD workflow
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Plans Workflow (Quick)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Fast task recording without full PRD/tasks workflow
- **When to use**: Tasks under 1 day, simple backlog items
- **Full version**: Use `plans.md` for complex multi-day work

**TODO.md Format**:

```markdown
- [ ] Task description @owner #tag ~estimate YYYY-MM-DD
```

<!-- AI-CONTEXT-END -->

## Quick Task Recording

For simple tasks that don't need full PRD/tasks workflow.

### After Planning Conversation

Present simplified choice:

```text
We've discussed [summary]. How would you like to proceed?

1. Execute now - Start immediately
2. Add to TODO.md - Record for later

Which option? (1-2)
```

### Adding to TODO.md

Add single line to appropriate section:

```markdown
## Backlog

- [ ] {description} @{owner} #{tag} ~{estimate}
```

**Format elements** (all optional except description):

| Element | Format | Example |
|---------|--------|---------|
| Description | Free text | `Add user dashboard` |
| Owner | `@name` | `@marcus` |
| Tag | `#category` | `#seo` `#security` |
| Estimate | `~duration` | `~2h` `~1d` `~1w` |
| Due date | `YYYY-MM-DD` | `2025-01-20` |

### Examples

```markdown
- [ ] Fix login timeout bug #auth ~2h
- [ ] Add export to CSV feature @marcus #feature ~4h
- [ ] Update dependencies #chore ~1h 2025-01-20
- [ ] Research Ahrefs API for MCP integration #seo ~3h
```

## Starting Work from TODO.md

When user references a task:

### 1. Find the Task

```text
Found in TODO.md:
- [ ] Add export to CSV feature @marcus #feature ~4h

1. Start working on this
2. View more details
3. Different task

Which option? (1-3)
```

### 2. Move to In Progress

Edit TODO.md to move task:

```markdown
## In Progress

- [ ] Add export to CSV feature @marcus #feature ~4h
```

### 3. Derive Branch Name

| Task | Branch |
|------|--------|
| `Add export to CSV feature #feature` | `feature/add-export-to-csv` |
| `Fix login timeout bug #auth` | `bugfix/fix-login-timeout` |
| `Update dependencies #chore` | `chore/update-dependencies` |

### 4. Follow git-workflow.md

Create branch and proceed with implementation.

## Completing Tasks

### Mark Done

Move to Done section with completion date:

```markdown
## Done

- [x] Add export to CSV feature @marcus #feature 2025-01-15
```

### Update CHANGELOG.md

For significant changes, add changelog entry per `workflows/changelog.md`.

## When to Upgrade to Full Plans

If during work you discover:
- Task is larger than expected (> 1 day)
- Multiple sub-tasks needed
- Design decisions required
- Research needed

Suggest upgrading:

```text
This task seems more complex than initially thought. Would you like to:

1. Continue with simple tracking
2. Create full execution plan in todo/PLANS.md

Which option? (1-2)
```

If option 2, follow `plans.md` workflow.

## Related

- `plans.md` - Full planning workflow with PRD/tasks
- `git-workflow.md` - Branch creation
- `changelog.md` - Recording changes
