---
mode: subagent
---
# TODO

Project task tracking with time estimates, dependencies, and TOON-enhanced parsing.

Compatible with [todo-md](https://github.com/todo-md/todo-md), [todomd](https://github.com/todomd/todo.md), [taskell](https://github.com/smallhadroncollider/taskell), and [Beads](https://github.com/steveyegge/beads).

## Format

**Human-readable:**

```markdown
- [ ] t001 Task description @owner #tag ~4h (ai:2h test:1h read:30m) logged:2025-01-15
- [ ] t002 Dependent task blocked-by:t001 ~2h
- [ ] t001.1 Subtask of t001 ~1h
- [x] t003 Completed task ~2h actual:1.5h logged:2025-01-10 completed:2025-01-15
- [-] Declined task
```

**Task IDs:**
- `t001` - Top-level task
- `t001.1` - Subtask of t001
- `t001.1.1` - Sub-subtask

**Dependencies:**
- `blocked-by:t001` - This task waits for t001
- `blocked-by:t001,t002` - Waits for multiple tasks
- `blocks:t003` - This task blocks t003

**Time fields:**
- `~estimate` - Total time with optional breakdown `(ai:Xh test:Xh read:Xm)`
- `actual:` - Actual time spent (recorded at commit/release)
- `logged:` - When task was added
- `started:` - When branch was created
- `completed:` - When task was marked done

<!--TOON:meta{version,format,updated}:
1.0,todo-md+toon,{{DATE}}
-->

## Ready

<!-- Tasks with no open blockers - run /ready to refresh -->

<!--TOON:ready[0]{id,desc,owner,tags,est,logged,status}:
-->

## Backlog

<!--TOON:backlog[0]{id,desc,owner,tags,est,est_ai,est_test,est_read,logged,status}:
-->

## In Progress

<!--TOON:in_progress[0]{id,desc,owner,tags,est,est_ai,est_test,est_read,logged,started,status}:
-->

## In Review

<!-- Tasks with open PRs awaiting merge -->

<!--TOON:in_review[0]{id,desc,owner,tags,est,pr_url,started,pr_created,status}:
-->

## Done

<!--TOON:done[0]{id,desc,owner,tags,est,actual,logged,started,completed,status}:
-->

## Declined

<!-- Tasks that were considered but decided against -->

<!--TOON:declined[0]{id,desc,reason,logged,status}:
-->

<!--TOON:dependencies-->
<!-- Format: child_id|relation|parent_id -->
<!--/TOON:dependencies-->

<!--TOON:subtasks-->
<!-- Format: parent_id|child_ids (comma-separated) -->
<!--/TOON:subtasks-->

<!--TOON:summary{total,ready,pending,in_progress,in_review,done,declined,total_est,total_actual}:
0,0,0,0,0,0,0,,
-->
