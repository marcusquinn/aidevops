---
id: no-todo-edit-by-worker
ttsr_trigger: (Edit|Write).*TODO\.md|todo/PLANS\.md|todo/tasks/
severity: error
repeat_policy: always
tags: [workflow, planning]
enabled: true
---

STOP: Workers must NOT edit TODO.md, todo/PLANS.md, or todo/tasks/*.

- The supervisor owns all TODO.md updates
- Report status via exit code, log output, and PR creation only
- Put task notes in commit messages or PR body, never in TODO.md
