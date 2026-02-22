---
id: no-edit-on-main
ttsr_trigger: git (commit|add|push).*main|on branch (main|master)
severity: error
repeat_policy: always
tags: [git, safety]
enabled: true
---

STOP: You are about to modify files on the main/master branch. This violates the git workflow.

- Run `~/.aidevops/agents/scripts/pre-edit-check.sh` before any file modifications
- Feature work must happen in worktrees: `wt switch -c feature/<name>`
- Main repo stays on `main` — never edit directly
- If pre-edit-check.sh returned exit 1, you must create a worktree first
