# t1833: Add priority account selection to model-accounts-pool rotate

**Session origin**: Interactive session, user request
**GitHub issue**: marcusquinn/aidevops#15184

## What
Add a `priority` field to oauth-pool accounts so rotate prefers accounts with higher priority. This lets users burn through accounts whose tokens/quota expire sooner.

## Why
Users with multiple provider accounts (e.g., personal + work Anthropic) want to maximize utilization by preferring the account whose billing cycle resets first. Current LRU-only rotation doesn't support this.

## How
1. In `_rotate_execute()` (line 1669 of `oauth-pool-helper.sh`), change sort key from `lastUsed` to `(-priority, lastUsed)`
2. Add `cmd_set_priority()` subcommand: `set-priority <provider> <email> <N>`
3. Update `cmd_list()` to display priority when set
4. Default priority = 0 (backwards compatible)

## Acceptance Criteria
- [ ] `oauth-pool.json` supports optional `priority` field (integer, higher = preferred)
- [ ] `_rotate_execute()` sorts by `(-priority, lastUsed)`
- [ ] `list` command shows priority when set
- [ ] `set-priority <provider> <email> <N>` subcommand works
- [ ] Backwards compatible — missing priority defaults to 0
- [ ] Existing tests/shellcheck pass

## Context
- File: `.agents/scripts/oauth-pool-helper.sh`
- Pool file: `~/.aidevops/oauth-pool.json`
- Rotation logic: lines 1524-1706
- List command: search for `cmd_list`
