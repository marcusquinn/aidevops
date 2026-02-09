---
description: List verification queue entries from todo/VERIFY.md with filtering
agent: Build+
mode: subagent
---

Display verification queue entries from todo/VERIFY.md with status filtering.

Arguments: $ARGUMENTS

## Quick Output (Default)

Run the helper script for instant output:

```bash
~/.aidevops/agents/scripts/list-verify-helper.sh $ARGUMENTS
```

Display the output directly to the user. The script handles all formatting.

## Fallback (Script Unavailable)

If the script fails or is unavailable, read and parse the file manually:

1. Read `todo/VERIFY.md`
2. Parse entries between `<!-- VERIFY-QUEUE-START -->` and `<!-- VERIFY-QUEUE-END -->`
3. Group by status: failed `[!]`, pending `[ ]`, passed `[x]`
4. Format as Markdown tables

## Arguments

**Filtering options:**

- `--pending` - Show only pending verifications `[ ]`
- `--passed` - Show only passed verifications `[x]`
- `--failed` - Show only failed verifications `[!]`
- `--task <id>` or `-t <id>` - Filter by task ID (e.g., `t168`)

**Display options:**

- `--compact` - One-line per entry (no tables)
- `--json` - Output as JSON
- `--no-color` - Disable colors

## Examples

```bash
/list-verify                   # All entries, grouped by status
/list-verify --pending         # Only pending verifications
/list-verify --failed          # Only failed (needs attention)
/list-verify -t t168           # Specific task verification
/list-verify --compact         # One-line per entry
/list-verify --json            # JSON output
```

## Output Format

The script outputs Markdown tables grouped by status (failed first, then pending, then passed):

```markdown
## Verification Queue

### Failed (N)

| # | Verify | Task | Description | PR | Merged | Reason |
|---|--------|------|-------------|-----|--------|--------|

### Pending (N)

| # | Verify | Task | Description | PR | Merged | Checks |
|---|--------|------|-------------|-----|--------|--------|

### Passed (N)

| # | Verify | Task | Description | PR | Merged | Verified |
|---|--------|------|-------------|-----|--------|----------|

**Summary:** N pending | N passed | N failed | N total
```

## After Display

Wait for user input:

1. **Verify ID** - Run verification checks for that entry (e.g., `v001`)
2. **"failed"** - Show only failed entries for triage
3. **"done"** - End browsing

## Related Commands

- `/list-todo` - List tasks from TODO.md
- `/ready` - Show tasks with no blockers
