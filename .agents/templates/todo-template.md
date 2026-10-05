---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# TODO

Project task tracking with time estimates, dependencies, and TOON-enhanced parsing.

Compatible with [todo-md](https://github.com/todo-md/todo-md),
[todomd](https://github.com/todomd/todo.md),
[taskell](https://github.com/smallhadroncollider/taskell).

## Format

**Human-readable:**

<!-- GH#17804: Format examples wrapped in HTML comment to prevent parsers
     from extracting them as real tasks during upgrade-planning migrations.
- [ ] t1 Task description @owner #tag ~30m risk:low logged:2025-01-15
- [ ] t2 Dependent task blocked-by:t1 ~15m risk:med
- [ ] t1.1 Subtask of t1 ~10m
- [x] t3 Completed task ~30m actual:25m logged:2025-01-10 completed:2025-01-15
- [-] Declined task
-->

Format: `- [ ] tN Description @owner #tag ~estimate risk:level logged:date`

**Task IDs:**

- `t1` - Top-level task (positive decimal, no leading zeros)
- `t1.1` - Subtask of t1
- `t1.1.1` - Sub-subtask

**Dependencies:**

- `blocked-by:t1` - This task waits for t1
- `blocked-by:t1,t2` - Waits for multiple tasks
- `blocks:t3` - This task blocks t3

**Time fields:**

- `~estimate` - AI-assisted execution time (~15m trivial, ~30m small, ~1h
  medium, ~2h large, ~4h major — see `reference/planning-detail.md`)
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

<!-- Counts are derived from the task sections above. -->
<!-- Do not cache a static summary. -->
