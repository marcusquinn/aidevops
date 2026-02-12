---
description: Allocate a new task ID with collision-safe distributed locking
agent: Build+
mode: subagent
---

Allocate a new task ID using `claim-task-id.sh` (distributed lock via GitHub/GitLab issue creation) and add it to TODO.md.

Topic/context: $ARGUMENTS

## Workflow

### Step 1: Determine Task Title

Extract the task title from the user's request. If no title is provided, ask for one.

### Step 2: Allocate Task ID

Run the wrapper function or script directly:

```bash
# Via planning-commit-helper.sh wrapper (preferred)
output=$(~/.aidevops/agents/scripts/planning-commit-helper.sh next-id --title "Task title here")

# Or directly via claim-task-id.sh
output=$(~/.aidevops/agents/scripts/claim-task-id.sh --title "Task title here" --repo-path "$(git rev-parse --show-toplevel)")
```

### Step 3: Parse Output

The output contains machine-readable variables:

```text
TASK_ID=tNNN
TASK_REF=GH#NNN
TASK_ISSUE_URL=https://github.com/user/repo/issues/NNN
TASK_OFFLINE=false
```

Parse these:

```bash
task_id=$(echo "$output" | grep '^TASK_ID=' | cut -d= -f2)
task_ref=$(echo "$output" | grep '^TASK_REF=' | cut -d= -f2)
task_offline=$(echo "$output" | grep '^TASK_OFFLINE=' | cut -d= -f2)
```

### Step 4: Present to User

Show the allocated ID and ask for task metadata:

```text
Allocated: {task_id} (ref:{task_ref})

Task: "{title}"
ID: {task_id}
Ref: ref:{task_ref}

Options:
1. Add to TODO.md with defaults (~1h #auto-dispatch)
2. Customize estimate, tags, and dependencies
3. Just show the ID (don't add to TODO.md)
```

### Step 5: Add to TODO.md (if requested)

Format the TODO.md entry using the allocated ID:

```markdown
- [ ] {task_id} {title} #{tag} #auto-dispatch ~{estimate} ref:{task_ref} logged:{YYYY-MM-DD}
```

Then commit and push via `planning-commit-helper.sh`:

```bash
~/.aidevops/agents/scripts/planning-commit-helper.sh "plan: add {task_id} {short_title}"
```

## Offline Handling

If `TASK_OFFLINE=true`, warn the user:

```text
[WARN] Allocated {task_id} in offline mode (+100 offset).
       Reconciliation required when back online.
       No GitHub/GitLab issue was created.
```

## Examples

```text
User: /new-task Add CSV export button
AI: Allocated: t325 (ref:GH#1260)
    Task: "Add CSV export button"
    1. Add to TODO.md with defaults  2. Customize  3. Just show ID
User: 1
AI: Added to TODO.md:
    - [ ] t325 Add CSV export button #auto-dispatch ~1h ref:GH#1260 logged:2026-02-12
```

```text
User: /new-task
AI: What's the task title?
User: Fix login timeout on mobile
AI: Allocated: t326 (ref:GH#1261)
    Task: "Fix login timeout on mobile"
    1. Add to TODO.md with defaults  2. Customize  3. Just show ID
User: 2
AI: Customize:
    - Estimate: ~2h
    - Tags: #bugfix
    - Dependencies: blocked-by:t300
    - Auto-dispatch: yes
    Confirm? [y/n]
```
