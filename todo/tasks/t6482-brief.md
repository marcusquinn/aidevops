# t6482: Redesign worktree auto-cleanup to prevent deletion of active work

## Origin

- **Created:** 2026-03-26
- **Session:** opencode (interactive research)
- **Created by:** ai-interactive
- **Conversation context:** User reported that pulse auto-cleanup deleted a worktree with a deliberate WIP commit in another project. Investigation revealed the cleanup logic is fundamentally inverted — it deletes by default and tries to guess what to keep, with multiple false-positive paths.

## What

A design document and implementation plan for safe worktree cleanup that eliminates the risk of deleting worktrees containing active work. The deliverable is this document (research phase) plus a concrete implementation plan for the chosen approach.

## Why

**Data loss risk.** The current `worktree-helper.sh clean --auto --force-merged` (called by pulse every 2 minutes across all managed repos) can delete worktrees that contain committed in-progress work. A user explicitly made a WIP commit as a defensive measure and the worktree was still deleted. This is a trust-breaking failure — if the safety net doesn't work, users lose confidence in the entire automation system.

**Root cause is architectural, not a missing edge case.** GH#5694 added safety checks (grace period, open PR, zero-commit+dirty), but the fundamental design — "delete unless we can prove it's active" — means every new edge case requires a new check. The correct inversion is "keep unless we can prove it's done."

---

## Root Cause Analysis

### The deletion pipeline

```text
pulse-wrapper.sh cleanup_worktrees()
  → for each repo in repos.json (non-local_only):
    → worktree-helper.sh clean --auto --force-merged
      → _clean_fetch_remotes()          # git fetch --prune (deletes remote refs!)
      → _clean_build_merged_pr_branches()  # gh pr list --state merged
      → _clean_build_open_pr_branches()    # gh pr list --state open
      → _clean_scan_merged()            # first pass: classify + display
        → _clean_classify_worktree()    # is it "merged"?
          → should_skip_cleanup()       # safety checks
      → _clean_remove_merged()          # second pass: actually delete
        → git worktree remove [--force]
        → git branch -D
```

### Three classification paths that produce false positives

**Path 1: `git branch --merged $default_br`** (`:1048`)

A branch whose tip is an ancestor of the default branch is flagged as "merged". This is correct for traditional merges but wrong when:
- A branch was created, work was done, a PR was merged (squash or rebase), and the developer still needs the worktree for follow-up work
- The branch was rebased onto main and the original commits are now ancestors

**Path 2: Remote branch deleted** (`:1055`)

After `git fetch --prune` removes the remote ref (GitHub auto-deletes branches after PR merge), the branch is flagged. But:
- A pushed WIP branch whose remote is manually deleted is treated as abandoned
- GitHub's "auto-delete head branches" setting triggers this for every merged PR, even if the developer is still using the worktree

**Path 3: Squash-merged PR** (`:1063`)

`gh pr list --state merged` matches the branch name. But merged PR != done working — the developer may need the worktree for follow-up, cherry-picks, or reference.

### Why GH#5694 safety checks don't cover this

| Safety check | What it catches | What it misses |
|---|---|---|
| Grace period (< 4h) | Fresh worktrees | Any work older than 4 hours |
| Open PR | Worktrees with open PRs | Work without a PR, or PR already merged |
| Zero-commit + dirty | Freshly created, uncommitted work | Any committed work (1+ commits = not zero-commit) |
| Dirty check | Uncommitted files (without `--force-merged`) | Clean worktrees (everything committed) |
| Ownership (PID alive) | Active sessions | Sessions that ended (PID dead) |

**The critical gap**: Once you commit your work, the worktree becomes "clean" — removing the only remaining barrier. And `--force-merged` (always passed by pulse) overrides the dirty check anyway.

### The confirmed attack scenario

1. Create worktree, work on feature
2. Make WIP commit (deliberate defensive action)
3. Push to remote, create PR
4. PR gets merged (or remote branch deleted for any reason)
5. Pulse runs cleanup (every ~2 min via `cleanup_worktrees()` in `pulse-wrapper.sh:2241`)
6. `git branch --merged` or "remote deleted" → `is_merged=true`
7. Worktree is clean (WIP committed) → dirty check passes
8. Grace period passed (>4h) → grace check passes
9. **Worktree deleted with all local work**

Git objects survive in the reflog temporarily, but the worktree directory and local branch ref are gone.

---

## Design Options Evaluation

### Option A: Disable auto-cleanup entirely

**How:** Remove the `cleanup_worktrees()` call from `pulse-wrapper.sh`. Manual cleanup via `worktree-helper.sh clean` (interactive, with confirmation).

| Criterion | Rating | Notes |
|---|---|---|
| Safety | **Excellent** | Zero risk of data loss — nothing is auto-deleted |
| Simplicity | **Excellent** | Delete code, not add code. Zero new bugs possible |
| User friction | **Low** | `worktree-helper.sh clean` already exists for manual use |
| Disk usage | **Low concern** | Worktrees share .git object store; 50 worktrees != 50 clones. Each worktree is just a working directory (~project size minus .git). Disk pressure only matters for very large repos with many worktrees |
| Compatibility | **Excellent** | No changes to worker lifecycle |

**Verdict:** Safest option. The right default until accumulation is proven to be a real problem.

### Option B: Lock file (.worktree-keep)

**How:** `worktree-helper.sh add` creates `.worktree-keep` automatically. Cleanup always skips worktrees with this file. Removed explicitly via `worktree-helper.sh done <branch>`. Workers call `done` after successful PR merge.

| Criterion | Rating | Notes |
|---|---|---|
| Safety | **Good** | Protected by default; only vulnerable if `.worktree-keep` is accidentally removed |
| Simplicity | **Moderate** | New file convention, new `done` command, worker lifecycle change |
| User friction | **Moderate** | Must remember to call `done` (or worktrees accumulate forever) |
| Disk usage | **Moderate** | Depends on `done` discipline; forgotten locks = permanent worktrees |
| Compatibility | **Moderate** | Requires worker lifecycle change (call `done` after merge) |

**Verdict:** Good opt-in protection, but adds a new lifecycle step that workers/users must remember. If `done` is forgotten, worktrees accumulate — trading one problem (premature deletion) for another (permanent accumulation).

### Option C: Soft delete (archive)

**How:** Instead of `rm -rf`, move to `~/Git/.archive/`. Auto-purge archive after 30 days. Always recoverable.

| Criterion | Rating | Notes |
|---|---|---|
| Safety | **Good** | Data is recoverable for 30 days |
| Simplicity | **Moderate** | New archive directory, purge cron, recovery command |
| User friction | **Low** | Transparent — user only notices if they need recovery |
| Disk usage | **Higher** | Archived worktrees consume disk for 30 days |
| Compatibility | **Good** | Drop-in replacement for the delete step |

**Verdict:** Good safety net, but doesn't fix the root cause — it just makes the damage recoverable. Still deletes worktrees the user is actively using, just with an undo window. The user still loses their working directory and has to manually recover.

### Option D: Separate bot/human worktrees

**How:** Mark worktrees at creation with creator type (headless worker vs interactive session). Auto-cleanup ONLY for bot-created worktrees. Human worktrees are never auto-cleaned.

| Criterion | Rating | Notes |
|---|---|---|
| Safety | **Good for humans** | Human worktrees are never touched |
| Simplicity | **Moderate** | Creator tracking in registry, classification logic |
| User friction | **None for humans** | Transparent |
| Disk usage | **Moderate** | Bot worktrees still cleaned; human worktrees accumulate |
| Compatibility | **Good** | Registry already tracks ownership (t189) |

**Verdict:** Addresses the reported incident (human worktree deleted). But bot worktrees with active work can still be deleted — a worker that crashes mid-task and is restarted would lose its worktree. Also, the bot/human distinction is fuzzy — a user might create a worktree interactively and then dispatch a worker to it.

### Option E: Age-based only (30+ days)

**How:** Remove merge detection entirely. Delete worktrees older than N days regardless of merge status.

| Criterion | Rating | Notes |
|---|---|---|
| Safety | **Moderate** | Predictable — user knows the deadline. But long-lived feature branches get deleted |
| Simplicity | **Good** | Simple age check, no merge detection complexity |
| User friction | **Low** | Predictable, but requires awareness of the deadline |
| Disk usage | **Good** | Bounded accumulation |
| Compatibility | **Good** | No dependency on PR state |

**Verdict:** Simple and predictable, but 30 days is arbitrary. Some feature branches legitimately live for months. And a 30-day-old worktree with active uncommitted work would still be deleted.

### Option F: Two-phase (mark → wait 24-48h → delete)

**How:** Pulse creates `.worktree-pending-removal` marker. After 24-48h, if not cancelled by user, actually deletes. Gives a window to intervene.

| Criterion | Rating | Notes |
|---|---|---|
| Safety | **Good** | 24-48h intervention window |
| Simplicity | **Moderate** | Marker file, timer logic, cancellation mechanism |
| User friction | **Moderate** | User must monitor for pending-removal markers |
| Disk usage | **Good** | Delayed cleanup, bounded |
| Compatibility | **Good** | Additive change to existing flow |

**Verdict:** Better than immediate deletion, but relies on the user noticing the marker within the window. In practice, users don't monitor worktree directories for marker files. The 24-48h delay also means stale worktrees accumulate longer.

### Option G: Combination D + C (bot→archive, human→never)

**How:** Bot worktrees → soft delete to archive. Human worktrees → never auto-clean.

| Criterion | Rating | Notes |
|---|---|---|
| Safety | **Good** | Human work protected; bot work recoverable |
| Simplicity | **Low** | Combines complexity of both D and C |
| User friction | **Low** | Transparent for humans |
| Disk usage | **Moderate** | Archive for bots, accumulation for humans |
| Compatibility | **Moderate** | Multiple new mechanisms |

**Verdict:** Comprehensive but complex. The combination of two mechanisms increases the surface area for bugs.

---

## Recommendation

### Phase 1 (immediate): Option A — Disable auto-cleanup

**Rationale:**

1. **The problem is architectural.** The current design deletes by default and tries to guess what to keep. Every new edge case requires a new safety check, and each check has its own failure modes. The issue documents 5 safety checks that all fail for the reported scenario. Adding a 6th check continues the pattern.

2. **Worktrees are cheap.** A linked worktree shares the .git object store with the main worktree. The only disk cost is the working directory files. For a typical project, this is tens of MB — negligible on modern systems. Even 50 stale worktrees across all repos is unlikely to cause disk pressure.

3. **Manual cleanup already works.** `worktree-helper.sh clean` (without `--auto`) prompts before removing. Users can run it when they want to clean up. `wt prune` (Worktrunk) also works.

4. **Zero new code = zero new bugs.** The safest change is removing code, not adding it.

**Implementation:**

```bash
# In pulse-wrapper.sh, replace cleanup_worktrees() body with:
cleanup_worktrees() {
    # Auto-cleanup disabled (GH#6482): worktree deletion is too risky for
    # automated execution. Use 'worktree-helper.sh clean' interactively.
    return 0
}
```

Optionally, add a periodic log message so the user knows worktrees are accumulating:

```bash
cleanup_worktrees() {
    local helper="${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
    [[ ! -x "$helper" ]] && return 0

    # Count total worktrees across all repos (for observability)
    local total_wt=0
    local repos_json="${HOME}/.config/aidevops/repos.json"
    if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
        local repo_path
        while IFS= read -r repo_path; do
            [[ -z "$repo_path" ]] && continue
            [[ ! -d "$repo_path/.git" ]] && continue
            local count
            count=$(git -C "$repo_path" worktree list 2>/dev/null | wc -l | tr -d ' ')
            total_wt=$((total_wt + count))
        done <<< "$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" 2>/dev/null || echo "")"
    fi

    if [[ "$total_wt" -gt 20 ]]; then
        echo "[pulse-wrapper] $total_wt worktrees across repos. Run 'worktree-helper.sh clean' to review." >> "$LOGFILE"
    fi

    return 0
}
```

**Also update:**
- `worktree-helper.sh` help text: note that `clean --auto` is deprecated
- `worktree.md`: update "Batch cleanup" section
- `commands/worktree-cleanup.md`: note auto-cleanup is disabled
- `full-loop.md` Step 4.8: update worktree cleanup guidance

### Phase 2 (if accumulation becomes a problem): Option D — Bot/human separation

Only implement if users report disk pressure from accumulated worktrees. The registry already tracks creator PID (t189); extending it to track `creator_type` (headless vs interactive) is straightforward.

Bot-created worktrees would be eligible for auto-cleanup after their PR is merged AND a configurable cool-down period (default 24h). Human-created worktrees would never be auto-cleaned.

This phase should be a separate task — don't bundle it with Phase 1.

### Phase 3 (optional): Option C — Soft delete as safety net

If Phase 2 is implemented, add soft-delete (move to `~/Git/.archive/`) as a safety net for bot worktree cleanup. This makes even bot worktree deletion recoverable.

---

## Acceptance Criteria

- [ ] `pulse-wrapper.sh cleanup_worktrees()` no longer deletes any worktrees automatically
  ```yaml
  verify:
    method: codebase
    pattern: "git worktree remove"
    path: ".agents/scripts/pulse-wrapper.sh"
    expect: absent
  ```
- [ ] `worktree-helper.sh clean` (interactive, without `--auto`) still works for manual cleanup
  ```yaml
  verify:
    method: bash
    run: "grep -q 'cmd_clean' .agents/scripts/worktree-helper.sh"
  ```
- [ ] Documentation updated to reflect auto-cleanup is disabled
  ```yaml
  verify:
    method: bash
    run: "grep -qi 'disabled\\|deprecated' .agents/workflows/worktree.md"
  ```
- [ ] Pulse logs worktree count when above threshold (observability)
  ```yaml
  verify:
    method: codebase
    pattern: "worktrees across repos"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] ShellCheck passes on modified files
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-wrapper.sh .agents/scripts/worktree-helper.sh"
  ```

## Relevant Files

- `.agents/scripts/worktree-helper.sh:927-994` — `should_skip_cleanup()` safety checks
- `.agents/scripts/worktree-helper.sh:1035-1084` — `_clean_classify_worktree()` merge detection
- `.agents/scripts/worktree-helper.sh:1129-1195` — `_clean_remove_merged()` actual deletion
- `.agents/scripts/worktree-helper.sh:1197-1263` — `cmd_clean()` entry point
- `.agents/scripts/pulse-wrapper.sh:2241-2299` — `cleanup_worktrees()` caller
- `.agents/scripts/pulse-wrapper.sh:3674` — `cleanup_worktrees` invocation in pulse pipeline
- `.agents/workflows/worktree.md` — worktree workflow documentation
- `.agents/scripts/commands/worktree-cleanup.md` — cleanup command documentation

## Dependencies

- **Blocked by:** None
- **Blocks:** None (this is a safety improvement)
- **External:** None

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Completed in this brief |
| Implementation (Phase 1) | 30m | Replace `cleanup_worktrees()`, update docs |
| Testing | 15m | Verify pulse runs without cleanup, manual clean still works |
| **Total** | **~1h15m** | |

## Context & Decisions

- **Why Option A over adding more safety checks:** The current design has 5 safety checks that all fail for the reported scenario. The issue is architectural — "delete by default, guess what to keep" is the wrong polarity. Adding a 6th check (e.g., "skip if has commits ahead") would fix this specific case but leave the door open for the next edge case. Disabling auto-cleanup eliminates the entire class of bugs.
- **Why not Option B (lock file):** Adds a new lifecycle step that workers and users must remember. Forgotten locks cause permanent accumulation — trading one problem for another.
- **Why not Option C (soft delete) as Phase 1:** Doesn't fix the root cause. The user still loses their working directory; they just get an undo window. The disruption (worktree disappears, user has to recover from archive) is still significant.
- **Why Phase 2 is separate:** Bot/human separation is a good idea but adds complexity. Phase 1 (disable) is zero-risk and can ship immediately. Phase 2 should only be implemented if disk accumulation is proven to be a real problem.
- **Disk cost of not cleaning:** A worktree's disk cost is approximately the size of the working directory (source files, build artifacts). The .git object store is shared. For most projects, this is 10-100 MB per worktree. Even 50 stale worktrees = 0.5-5 GB, well within modern disk capacity. Build artifacts (node_modules, .next) are the main cost — these could be cleaned separately without deleting the worktree itself.
