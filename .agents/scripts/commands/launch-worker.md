---
description: Manually launch headless workers against one or more GitHub issues.
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Args: `$ARGUMENTS` — `<issue|issue,issue> [owner/repo] [--model <id>] [--agent <name>] [--batch <list>] [--dry-run]`

`owner/repo` is optional. When omitted, `aidevops launch-worker` resolves the
current git repository from `origin` and dispatches against that repo.

## What this does

Runs the first-class manual worker launcher:

```bash
aidevops launch-worker $ARGUMENTS
```

Use it when an operator needs to start workers intentionally instead of waiting
for the next pulse cycle: smoke-testing a new issue, retrying after fixing a
dispatch blocker, or launching a controlled batch with a specific model.

## Syntax

```bash
# Preview one dispatch without launching, using the current git repo
aidevops launch-worker 22259 --dry-run

# Preview one dispatch without launching, using an explicit repo
aidevops launch-worker 22259 marcusquinn/aidevops --dry-run

# Launch one issue with default agent Build+ in the current repo
aidevops launch-worker 22259

# Launch multiple issues in the current repo with repeated issue arguments
aidevops launch-worker 22259 22260 22261

# Batch launch multiple issues in the current repo
aidevops launch-worker --batch 22259,22260 --dry-run

# Force a model and agent
aidevops launch-worker 22259 marcusquinn/aidevops \
  --model anthropic/claude-opus-4-7 --agent Build+

# Batch launch against an explicit repo
aidevops launch-worker --batch 22259,22260 marcusquinn/aidevops --dry-run

# Status for the current repo
aidevops launch-worker status 22259
```

## Safety expectations

The launcher delegates to `dispatch-single-issue-helper.sh dispatch`, preserving
the manual-dispatch ceremony: issue must be open, parent tasks are blocked,
dedup is checked fail-closed, status moves to `status:queued`, `origin:worker`
is applied, the runner is assigned, a worktree is created from `origin/<default>`,
and the dispatch ledger is registered.

## Output

Successful real launches print:

- Worker PID
- Issue and repo
- Tier/model
- Worktree path
- Log path
- Session key
- Status command

## Related

- `aidevops pulse status` — inspect the normal dispatcher.
- `dispatch-single-issue-helper.sh dispatch` — backend used by this command.
- `dispatch-ledger-helper.sh check-issue` — ledger source for status output.
