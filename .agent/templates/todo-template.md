# TODO

Project task tracking with time estimates and TOON-enhanced parsing.

Compatible with [todo-md](https://github.com/todo-md/todo-md), [todomd](https://github.com/todomd/todo.md), and [taskell](https://github.com/smallhadroncollider/taskell).

## Format

**Human-readable:**
```markdown
- [ ] Task description @owner #tag ~4h (ai:2h test:1h read:30m) logged:2025-01-15
- [x] Completed task ~2h actual:1.5h logged:2025-01-10 completed:2025-01-15
- [-] Declined task
```

**Time fields:**
- `~estimate` - Total time with optional breakdown `(ai:Xh test:Xh read:Xm)`
- `actual:` - Actual time spent (recorded at commit/release)
- `logged:` - When task was added
- `started:` - When branch was created
- `completed:` - When task was marked done

<!--TOON:meta{version,format,updated}:
1.0,todo-md+toon,{{DATE}}
-->

## Backlog

<!--TOON:backlog[0]{id,desc,owner,tags,est,est_ai,est_test,est_read,logged,status}:
-->

## In Progress

<!--TOON:in_progress[0]{id,desc,owner,tags,est,est_ai,est_test,est_read,logged,started,status}:
-->

## Done

<!--TOON:done[0]{id,desc,owner,tags,est,actual,logged,started,completed,status}:
-->

## Declined

<!-- Tasks that were considered but decided against -->

<!--TOON:declined[0]{id,desc,reason,logged,status}:
-->

<!--TOON:summary{total,pending,in_progress,done,declined,total_est,total_actual}:
0,0,0,0,0,,
-->
