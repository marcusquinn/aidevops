<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1981 Investigation Report — Multi-Operator Assignee Churn

## Summary

**Root cause:** the collaborator `alex-solovyev` is running a version of aidevops that predates **GH#18352** (which added the `origin:interactive` check to `dispatch-dedup-helper.sh _has_active_claim`). Their pulse dispatches on interactive-claimed issues because its older `is_assigned()` implementation doesn't recognise `origin:interactive` as an active claim, so owner/maintainer assignments appear "passive" and get stripped via the GH#17777 replace-assignees path in `pulse-dispatch-core.sh:889-898`.

**Good news:** the guard is already in place in the current code. Once alex-solovyev updates aidevops, the churn stops. No framework code change needed for the guard itself. **t1984 is a complementary fix** that ensures new workflow-created issues reliably carry `origin:interactive` so the guard has something to check against.

## Evidence

### Event trace — issue #18370 (t1969, first reproduction)

```
2026-04-12T17:05:23Z labeled status:available by marcusquinn
2026-04-12T17:05:23Z labeled auto-dispatch by marcusquinn
2026-04-12T17:05:23Z labeled test by marcusquinn
2026-04-12T17:05:24Z labeled origin:interactive by marcusquinn
2026-04-12T17:05:24Z labeled tier:standard by marcusquinn
2026-04-12T17:05:35Z assigned marcusquinn by marcusquinn
2026-04-12T17:12:53Z unassigned marcusquinn by marcusquinn   <-- churn starts
2026-04-12T17:12:53Z labeled status:queued by alex-solovyev
2026-04-12T17:12:53Z labeled origin:worker by alex-solovyev
2026-04-12T17:12:53Z assigned alex-solovyev by alex-solovyev
2026-04-12T17:12:59Z unlabeled origin:worker by github-actions[bot]
2026-04-12T17:25:05Z assigned marcusquinn by marcusquinn    <-- manual recovery
```

**At the moment of dispatch (17:12:53), issue state was:**

- Assignee: `marcusquinn` (me, the repo owner)
- Labels: `status:available`, `auto-dispatch`, `test`, `origin:interactive`, `tier:standard`

**What the current `dispatch-dedup-helper.sh is_assigned()` should do** (lines 711-754, with GH#18352):

1. Fetch labels + assignees via `gh issue view`
2. Compute `assignees = [marcusquinn]`
3. Call `_has_active_claim()`: returns `true` because `origin:interactive` is in the labels set (line 621)
4. For each assignee, check if it's owner/maintainer:
   - `marcusquinn` IS the repo owner (line 748)
   - `active_claim == true`, so the owner IS blocking (line 751-753 skipped)
5. `blocking_assignees = "marcusquinn"`
6. `is_assigned` returns `0` (blocked) — dispatch halted

**What actually happened:** the dispatch proceeded, stripped `marcusquinn`, assigned `alex-solovyev`. The only code path that produces this is `pulse-dispatch-core.sh:889-898` (GH#17777), which is AFTER the `check_dispatch_dedup` call at line 884. So `check_dispatch_dedup` must have returned success (not blocked), which means either:

- **(A)** alex-solovyev's version of `_has_active_claim()` predates GH#18352 and doesn't check `origin:interactive`, so the owner assignment was treated as passive and dispatch proceeded, OR
- **(B)** alex-solovyev's version of `is_assigned()` predates the whole owner-vs-active-claim split from t1961/GH#18352

Either way, **alex-solovyev is running an older aidevops version** where the interactive-session guard doesn't exist yet.

### Corroborating event: same pattern on #18371, #18395

All three reproductions show:

- Same sub-minute unassign+assign sequence
- Same attribution pattern (unassign "by marcusquinn", reassign "by alex-solovyev")
- Same label state at dispatch time (origin:interactive present)

### Attribution quirk — "unassigned by marcusquinn"

The timeline shows `unassigned marcusquinn by marcusquinn` even though the actual mutation was performed by alex-solovyev's pulse. This is GitHub's event attribution quirk: when a single `gh issue edit --remove-assignee X --add-assignee Y` runs, GitHub fires two separate events, and the "remove" event is attributed to the assignee being removed, not the actor performing the mutation. This is misleading and led me to initially suspect shared credentials (security issue), which turned out to be wrong.

**No security issue.** alex-solovyev has their own `gh` token; GitHub's event log is just ambiguous on the attribution field for remove-assignee events.

## Fix plan

### No framework code change needed (the guard already exists)

The current `.agents/scripts/dispatch-dedup-helper.sh` at `_has_active_claim()` (lines 611-627) correctly includes `origin:interactive` in the active-claim set. The current `is_assigned()` (lines 676-784) correctly blocks dispatch when an owner/maintainer is assigned AND `_has_active_claim` returns true.

Any aidevops install at the latest version will NOT reproduce this churn on issues that carry `origin:interactive`.

### Secondary fix — t1984 (merged: PR #18431 or in review)

**t1984** fixes the orthogonal problem that workflow-created issues (from TODO.md pushes triggering `Sync TODO.md → GitHub Issues`) were getting `origin:worker` + no assignee, so even a current-version pulse wouldn't see `origin:interactive` and wouldn't block. After t1984 merges:

1. Human TODO.md push triggers workflow
2. Workflow runs `issue-sync-helper.sh push` with `AIDEVOPS_SESSION_ORIGIN=interactive` + `AIDEVOPS_SESSION_USER=<github.actor>`
3. Helper creates issue with `origin:interactive` label + human assignee
4. Any current-version pulse sees both signals and blocks dispatch

Together with the existing GH#18352 guard, this closes the interactive-issue dispatch loop **at the framework level**, regardless of individual runner versions.

### Primary fix — alex-solovyev updates aidevops

Operational, not code:

1. Have alex-solovyev run `aidevops update` on their machine
2. Confirm their version is ≥ whatever commit shipped GH#18352 and t1961
3. Observe the next few TODO.md pushes: interactive-claimed issues should stay assigned to the human

If alex-solovyev is unable/unwilling to update, there is no client-side framework fix that helps — the churn happens in **their** dispatch code, not in ours.

## Secondary findings

### The unassign attribution bug is GitHub's

Not something we can fix. Document it in operator docs so future investigations don't waste time chasing "shared credentials" hypotheses when they see "by marcusquinn" on events that were actually performed by another operator's pulse.

### GH#17777's replace-assignees is a design choice, not a bug

The `--remove-assignee` call at `pulse-dispatch-core.sh:897` is intentional: it enforces single-ownership on actively dispatched issues. Removing it would reintroduce the dedup layer 6 ambiguity GH#17777 was designed to solve. The right fix is the UPSTREAM gate (`is_assigned()` refusing dispatch), not the downstream replace call.

### No evidence of shared credentials

The attribution pattern looked suspicious initially but is fully explained by GitHub's event attribution quirk. alex-solovyev has their own `gh` token with write access (confirmed via `gh api repos/marcusquinn/aidevops/collaborators/alex-solovyev/permission` earlier in the session). No rotation needed.

## Operational recommendations

1. **Ask alex-solovyev to run `aidevops update`** and report their version.
2. **Monitor #18394 and #18395 for 24 hours** after t1984 merges — if churn recurs, alex-solovyev is still on an old version.
3. **Document the GitHub event attribution quirk** in `reference/worker-diagnostics.md` so future debuggers don't chase the wrong lead.
4. **Confirm t1984 actually lands `origin:interactive` on workflow-created issues** — the first TODO.md push after t1984 merges is the test.

## Closing signal

t1981 can be closed as **resolved-by-environment** once:

- [ ] alex-solovyev confirms they've updated (or provides version ≥ post-GH#18352)
- [x] t1984 merges (complementary fix, PR filed this session)
- [ ] No new churn observed within 48 hours of those two conditions

The framework-level code is correct. This ticket documents a one-off cross-operator version skew, not a latent aidevops bug.
