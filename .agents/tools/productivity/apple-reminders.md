---
description: Create and manage Apple Reminders from agent sessions
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Apple Reminders

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/reminders-helper.sh [command] [args]`
- **Underlying tool**: `remindctl` (`brew install steipete/tap/remindctl`)
- **Setup**: `reminders-helper.sh setup` (install + authorize)
- **Related**: `tools/productivity/caldav-calendar-skill.md` (calendar events, not tasks)
- **macOS only** — uses EventKit via `remindctl`

<!-- AI-CONTEXT-END -->

## When Agents Should Create Reminders

Create a reminder when:

- User explicitly asks ("remind me to...", "set a reminder for...")
- A task has a deadline the user needs to act on outside the dev session
- A routine/mission produces a follow-up that requires human action
- Waiting on an external dependency with a check-back date
- User needs to do something in the physical world (calls, meetings, purchases)

Do NOT create reminders for:

- Things tracked in TODO.md / GitHub issues (that's the task system)
- Automated checks (use launchd/cron instead)
- Things the agent can do itself in a future session

## List Selection

Ask the user which list to use if unclear. Common patterns:

| Context | Likely list | Priority |
|---------|-------------|----------|
| Work tasks, deadlines | Work | medium-high |
| Personal errands | Personal / Reminders | low-medium |
| Shopping items | Shopping / Groceries | none-low |
| Health/medical | Personal | medium |
| Calls to make | Personal | medium |
| Bills/payments | Personal or Finance | high |

If the user has configured a default list mapping in their config, use it. Otherwise infer from context and confirm on first use.

## Usage

### List available lists

```bash
reminders-helper.sh lists
```

### Create a reminder

```bash
# Simple
reminders-helper.sh add "Buy milk" --list Shopping

# With due date and priority
reminders-helper.sh add "Review quarterly report" --list Work --due "next Friday" --priority high

# With notes
reminders-helper.sh add "Call dentist" --due "Monday 9am" --notes "Ask about cleaning schedule"

# Natural date expressions (handled by remindctl)
reminders-helper.sh add "Submit tax return" --due "April 15" --priority high --list Personal
```

### View reminders

```bash
reminders-helper.sh show today
reminders-helper.sh show overdue --list Work
reminders-helper.sh show week
reminders-helper.sh show upcoming
```

### Complete a reminder

```bash
# Use index from show output
reminders-helper.sh complete 1
```

### JSON output (for agent parsing)

```bash
JSON_OUTPUT=true reminders-helper.sh lists
reminders-helper.sh show today --json
```

## Due Date Formats

`remindctl` accepts natural language dates:

- `today`, `tomorrow`, `next Monday`
- `in 2 hours`, `in 3 days`
- `2026-04-15`, `April 15`
- `next week`, `end of month`

## Setup (One-Time)

Run `reminders-helper.sh setup` or manually:

1. `brew install steipete/tap/remindctl`
2. `remindctl authorize` (triggers macOS permission prompt)
3. System Settings > Privacy & Security > Reminders > enable your terminal app
4. Verify: `remindctl list` (should show your reminder lists)

If using multiple accounts (iCloud + other CalDAV), all accounts configured in System Settings > Internet Accounts appear automatically — no extra setup per account.

## Integration with Routines and Missions

Other agents should create reminders by calling the helper script directly:

```bash
# From any agent with bash access:
~/.aidevops/agents/scripts/reminders-helper.sh add "Follow up with client" \
  --list Work --due "in 3 days" --priority medium \
  --notes "Re: proposal sent on $(date +%Y-%m-%d)"
```

### Routine integration

When a `/routine` produces a human-action follow-up:

```bash
reminders-helper.sh add "ACTION: ${follow_up_description}" \
  --list Work --due "${deadline}" --priority "${urgency}"
```

### Mission integration

When a mission identifies a time-sensitive human dependency:

```bash
reminders-helper.sh add "MISSION: ${mission_name} — ${action_needed}" \
  --list Work --due "${target_date}" --notes "Mission context: ${details}"
```

## Accounts

All accounts configured in macOS System Settings > Internet Accounts (iCloud, Google, Fastmail, CalDAV, etc.) are accessible. `remindctl` sees every list across all accounts. The list name is the selector — no need to specify the account explicitly.

If two accounts have lists with the same name, `remindctl` uses the default account's list. Rename one list to disambiguate.
