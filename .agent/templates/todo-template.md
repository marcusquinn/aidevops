---
mode: subagent
---
# TODO

Project task tracking with time estimates, dependencies, and TOON-enhanced parsing.

Compatible with [todo-md](https://github.com/todo-md/todo-md), [todomd](https://github.com/todomd/todo.md), [taskell](https://github.com/smallhadroncollider/taskell), and [Beads](https://github.com/steveyegge/beads).

## Format

**Human-readable:**

```markdown
- [ ] t001 Task description @owner #tag ~30m risk:low logged:2025-01-15
- [ ] t002 Dependent task blocked-by:t001 ~15m risk:med
- [ ] t001.1 Subtask of t001 ~10m
- [x] t003 Completed task ~30m actual:25m logged:2025-01-10 completed:2025-01-15
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
- `~estimate` - Active session time (AI execution, not wall clock)
- `actual:` - Actual active time spent (from session-time-helper.sh)
- `logged:` - When task was added
- `started:` - When branch was created
- `completed:` - When task was marked done

**Risk (human oversight needed):**
- `risk:low` - Autonomous: fire-and-forget, review PR after
- `risk:med` - Supervised: check in mid-task, review before merge
- `risk:high` - Engaged: stay present, test thoroughly, potential regressions

<!--TOON:meta{version,format,updated}:
1.1,todo-md+toon,{{DATE}}
-->

## Ready

<!-- Tasks with no open blockers - run /ready to refresh -->

<!--TOON:ready[0]{id,desc,owner,tags,est,risk,logged,status}:
-->

## Backlog

<!--TOON:backlog[0]{id,desc,owner,tags,est,risk,logged,status}:
-->

## In Progress

<!--TOON:in_progress[0]{id,desc,owner,tags,est,risk,logged,started,status}:
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
