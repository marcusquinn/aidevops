---
description: Graduate validated memories into shared documentation
agent: Build+
mode: subagent
model: haiku
---

Promote validated local memories into shared codebase documentation.

Arguments: $ARGUMENTS

## Instructions

1. Check graduation status first:

```bash
~/.aidevops/agents/scripts/memory-graduate-helper.sh status
```

2. Show candidates for graduation:

```bash
~/.aidevops/agents/scripts/memory-graduate-helper.sh candidates
```

3. If arguments include `--dry-run`, preview without writing:

```bash
~/.aidevops/agents/scripts/memory-graduate-helper.sh graduate --dry-run
```

4. If the user confirms (or no `--dry-run`), graduate the memories:

```bash
~/.aidevops/agents/scripts/memory-graduate-helper.sh graduate
```

5. After graduation, remind the user to commit the updated
   `.agents/aidevops/graduated-learnings.md` file.

6. If no candidates are found, explain:
   - Memories qualify when confidence is "high" or access_count >= 3
   - Use `/remember` to store learnings manually
   - Use `--confidence high` when storing important learnings
   - Frequently recalled memories auto-qualify over time
