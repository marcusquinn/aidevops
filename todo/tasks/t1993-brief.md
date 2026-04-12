---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1993: Schedule post-merge-review-scanner.sh as a pulse routine — orphan helper not being invoked

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) via ai-interactive
- **Parent task:** none
- **Conversation context:** After merging PR #18405 (t1982 consolidation fix), Gemini Code Assist posted a medium-priority finding on `.agents/scripts/pulse-triage.sh:750` suggesting the jq-in-loop pattern in `_backfill_stale_consolidation_labels` should be consolidated. The user asked whether the daily code quality sweep would catch it. Investigation found (a) the sweep is broken (tracked as t1992) and (b) there's a purpose-built helper `post-merge-review-scanner.sh` specifically designed to catch this class of finding — but it's never invoked. Not scheduled in launchd, not in crontab, not called from the pulse, not in any TODO routine.

## What

Wire `.agents/scripts/post-merge-review-scanner.sh scan` into the pulse as a scheduled routine so that inline review comments from AI bots (CodeRabbit, Gemini Code Assist, claude-review, gpt-review) on recently merged PRs are automatically turned into `review-followup` issues on the next pulse cycle.

Two deliverables:

1. **Scheduling**: add a routine that invokes the scanner regularly. Two options:
   - **Option A (preferred)**: add a new `_run_post_merge_review_scanner` helper in `pulse-simplification.sh` alongside `run_daily_codebase_review` and `run_weekly_complexity_scan`, wire it into `pulse-dispatch-engine.sh` pre-dispatch stages. Runs every pulse cycle (lightweight — only scans recent merges) with a daily time-gate so we don't spam. This matches the existing pattern used by the other pulse-native periodic tasks.
   - **Option B (fallback)**: add a TODO.md routine entry `- [x] rNNN` with `repeat: daily(@03:00)` and `run: scripts/post-merge-review-scanner.sh scan marcusquinn/aidevops`. This is the same cadence as the current milohiss sweep, lives outside the pulse code path, and is easier to disable if it misbehaves.

2. **Backfill**: one-shot historical scan of the last 30 days of merged PRs (`SCANNER_DAYS=30 post-merge-review-scanner.sh scan marcusquinn/aidevops`) to capture any review findings already missed, including Gemini's #18405 finding about `_backfill_stale_consolidation_labels`. This is a one-time invocation executed as part of implementing this task (not added to the recurring routine).

The implementer should pick Option A or Option B based on a quick audit of how `run_daily_codebase_review` is structured. My recommendation is Option A for consistency, but if the scanner needs more isolation from the pulse cycle's budget constraints, Option B is acceptable.

## Why

`post-merge-review-scanner.sh` already exists, is complete, has a dedup guard (`issue_exists()`), has an explicit bot allow-list (`coderabbitai|gemini-code-assist|claude-review|gpt-review`), and an actionable-keyword filter (`should|consider|fix|change|update|refactor|missing|add`). It's purpose-built for exactly this use case. It was created as part of t1386 (GH#2785). But the scheduling step was never done — or was dropped during a refactor — so the scanner is orphaned.

Concrete evidence of the gap, discovered while investigating this session's PR:

- PR #18405 merged 2026-04-12T19:20:21Z with Gemini Code Assist posting a medium-priority actionable finding on `pulse-triage.sh:750` recommending jq consolidation.
- The finding matches `BOT_RE` (gemini-code-assist) and `ACT_RE` (body contains "Refactoring", "inefficient", "should").
- No `review-followup` issue was created.
- No mention of `post-merge-review-scanner.sh` in `~/.aidevops/logs/pulse.log`, `~/.aidevops/logs/stats.log`, any `~/Library/LaunchAgents/` plist, or `crontab -l`.
- The helper is listed alphabetically in `~/.aidevops/logs/routine-gh-failure-miner.log` but that's just a directory listing, not an invocation.

The scheduling gap means every Gemini/CodeRabbit inline suggestion on a merged PR goes into a black hole. This has almost certainly been the case for weeks or months. Backfilling 30 days of merged PRs should surface a non-trivial batch of unaddressed review comments — each one a small optimization or bugfix that was silently dropped.

Compared to t1992 (sweep serialization): the sweep runs tools on the current HEAD and surfaces aggregate counts. This scanner reads actual reviewer content from PR threads and surfaces specific actionable suggestions with file:line context. The two are complementary — together they close the quality feedback loop.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** → yes (Option A: `pulse-simplification.sh` + `pulse-dispatch-engine.sh`; Option B: `TODO.md` + add routine script if needed — still ≤ 2)
- [x] **Complete code blocks for every edit?** → yes, skeletons for both options provided below
- [ ] **No judgment or design decisions?** → no (Option A vs Option B requires reading `run_daily_codebase_review` to decide consistency)
- [x] **No error handling or fallback logic to design?** → yes (scanner already has its own error handling; integration is a single call)
- [x] **Estimate 1h or less?** → yes (~45m implementation + 15m backfill verification)
- [ ] **4 or fewer acceptance criteria?** → no (6 criteria)

**Selected tier:** `tier:simple`

**Tier rationale:** Scheduling an existing helper is a near-mechanical edit once the option is chosen. The one judgment call (A vs B) is small and has a clear default (Option A for consistency with `run_daily_codebase_review`). Code volume is minimal — the scanner already handles all the logic. This is genuinely `tier:simple` work.

## How (Approach)

### Files to Modify

**Option A (preferred — pulse-native, matches `run_daily_codebase_review`)**:

- `EDIT: .agents/scripts/pulse-simplification.sh` — add `_run_post_merge_review_scanner()` function mirroring `run_daily_codebase_review()` (lines 116-163). Time-gated via a new `POST_MERGE_SCANNER_LAST_RUN` file, 24h interval, cross-repo loop if we want to scan all pulse-enabled repos.
- `EDIT: .agents/scripts/pulse-wrapper.sh` — add the `POST_MERGE_SCANNER_LAST_RUN` + `POST_MERGE_SCANNER_INTERVAL` constants in the same section as `CODERABBIT_REVIEW_LAST_RUN` (lines ~433-435).
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh` — add a call to `_run_post_merge_review_scanner` next to `run_daily_codebase_review` (line ~761).

**Option B (fallback — TODO routine)**:

- `EDIT: TODO.md` — add a new `- [x] r0NN` routine under the `## Routines` section with `repeat: daily(@03:00)`, `run: scripts/post-merge-review-scanner.sh scan marcusquinn/aidevops`, and appropriate SCANNER_DAYS env override.

### Implementation Steps (Option A)

1. **Read the pattern to mirror.** `.agents/scripts/pulse-simplification.sh:116-163` — `run_daily_codebase_review` is the template. It time-gates via `_coderabbit_review_check_interval`, checks maintainer permission via `gh api ... collaborators/$user/permission`, posts a trigger comment, and updates a last-run file.

   Our scanner is simpler — no maintainer permission gate needed (the scanner uses `gh_create_issue` which already respects repo write access), no trigger comment (the scanner posts issues directly). Just time-gate + invoke.

2. **Add the helper in `pulse-simplification.sh`** (insert after `run_daily_codebase_review`):

   ```bash
   #######################################
   # Daily post-merge review scanner.
   #
   # Scans recently merged PRs in pulse-enabled repos for actionable AI bot
   # review comments (CodeRabbit, Gemini, claude-review, gpt-review) and
   # creates review-followup issues. Idempotent via existing dedup in the
   # scanner itself. Time-gated to run at most once per POST_MERGE_SCANNER_INTERVAL.
   #
   # Reference pattern: run_daily_codebase_review (lines 116-163).
   #######################################
   _run_post_merge_review_scanner() {
       local now_epoch
       now_epoch=$(date +%s)

       # Time gate: skip if last run was <24h ago
       if [[ -f "$POST_MERGE_SCANNER_LAST_RUN" ]]; then
           local last_run
           last_run=$(cat "$POST_MERGE_SCANNER_LAST_RUN" 2>/dev/null || echo "0")
           [[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
           local elapsed=$((now_epoch - last_run))
           if [[ "$elapsed" -lt "$POST_MERGE_SCANNER_INTERVAL" ]]; then
               return 0
           fi
       fi

       local scanner="${SCRIPT_DIR}/post-merge-review-scanner.sh"
       [[ -x "$scanner" ]] || {
           echo "[pulse-wrapper] Post-merge scanner: helper not found or not executable: $scanner" >>"$LOGFILE"
           return 0
       }

       # Iterate pulse-enabled repos; scan each. Scanner is idempotent —
       # existing review-followup issues are skipped via issue_exists().
       local repos_json="$REPOS_JSON"
       [[ -f "$repos_json" ]] || return 0

       local total_repos=0
       while IFS= read -r slug; do
           [[ -n "$slug" ]] || continue
           total_repos=$((total_repos + 1))
           echo "[pulse-wrapper] Post-merge scanner: scanning $slug" >>"$LOGFILE"
           SCANNER_DAYS="${SCANNER_DAYS:-7}" "$scanner" scan "$slug" >>"$LOGFILE" 2>&1 || true
       done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

       printf '%s\n' "$now_epoch" >"$POST_MERGE_SCANNER_LAST_RUN"
       echo "[pulse-wrapper] Post-merge scanner: completed ${total_repos} repo(s), next run in ~$((POST_MERGE_SCANNER_INTERVAL / 3600))h" >>"$LOGFILE"
       return 0
   }
   ```

3. **Add constants in `pulse-wrapper.sh`** near the existing CodeRabbit constants (around lines 433-435):

   ```bash
   POST_MERGE_SCANNER_LAST_RUN="${HOME}/.aidevops/logs/post-merge-scanner-last-run"
   POST_MERGE_SCANNER_INTERVAL="${POST_MERGE_SCANNER_INTERVAL:-86400}"  # 1 day in seconds
   ```

   And add validation near line 489:

   ```bash
   POST_MERGE_SCANNER_INTERVAL=$(_validate_int POST_MERGE_SCANNER_INTERVAL "$POST_MERGE_SCANNER_INTERVAL" 86400 3600)
   ```

4. **Wire into the dispatch engine** at `pulse-dispatch-engine.sh:761` (after `run_daily_codebase_review`):

   ```bash
   # Daily post-merge review scanner: ingests inline AI bot review comments
   # from recently merged PRs into review-followup issues. Time-gated to
   # 24h; scans all pulse-enabled repos via scanner's own dedup.
   run_stage_with_timeout "post_merge_scanner" "$PRE_RUN_STAGE_TIMEOUT" _run_post_merge_review_scanner || true
   ```

5. **Update the characterization test** at `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` to add `_run_post_merge_review_scanner` to the function-existence list. Search the file for `run_daily_codebase_review` and add the new function name next to it.

6. **Execute the one-shot backfill** (not part of the recurring routine — runs once during implementation verification):

   ```bash
   SCANNER_DAYS=30 bash .agents/scripts/post-merge-review-scanner.sh scan marcusquinn/aidevops
   ```

   Capture the list of created `review-followup` issues. Expect to see at least one issue referencing PR #18405 and the jq-in-loop finding on `pulse-triage.sh:750` — that's the known repro case.

### Implementation Steps (Option B — only if Option A is rejected)

1. Add routine entry to `TODO.md` under `## Routines`:

   ```
   - [x] r0NN post-merge review scanner — scan merged PRs for unactioned AI bot review feedback and create review-followup issues daily #routine repeat:daily(@03:00) run:scripts/post-merge-review-scanner.sh
   ```

2. The routine's `run:` points to the scanner directly. The routine dispatcher will invoke `scripts/post-merge-review-scanner.sh scan` — verify the scanner accepts zero-arg invocation for the default repo, or extend the routine `run:` to pass `scan marcusquinn/aidevops` explicitly.

3. Run backfill same as Option A step 6.

### Verification

```bash
# After implementation
shellcheck .agents/scripts/pulse-simplification.sh \
  .agents/scripts/pulse-wrapper.sh \
  .agents/scripts/pulse-dispatch-engine.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# Backfill + verify the Gemini finding on PR #18405 is captured
SCANNER_DAYS=30 bash .agents/scripts/post-merge-review-scanner.sh scan marcusquinn/aidevops
gh issue list --repo marcusquinn/aidevops --label review-followup --state open --limit 20
# Expect: at least one issue mentioning "PR #18405" and "pulse-triage.sh" or "jq"
```

## Acceptance Criteria

- [ ] `_run_post_merge_review_scanner` (Option A) exists in `pulse-simplification.sh` OR a `## Routines` entry (Option B) exists in `TODO.md` that invokes the scanner on a daily cadence.
  ```yaml
  verify:
    method: codebase
    pattern: "_run_post_merge_review_scanner|post-merge-review-scanner"
    path: ".agents/scripts/pulse-simplification.sh"
  ```
- [ ] The scheduling invocation is time-gated to at most once per 24h (prevent duplicate scans within a day).
  ```yaml
  verify:
    method: codebase
    pattern: "POST_MERGE_SCANNER_(LAST_RUN|INTERVAL)|repeat:\\s*daily"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] The pulse dispatch engine calls the scheduler helper (Option A) OR the routine is marked `[x]` enabled (Option B).
  ```yaml
  verify:
    method: codebase
    pattern: "_run_post_merge_review_scanner|r0[0-9]{2} post-merge"
    path: ".agents/scripts/pulse-dispatch-engine.sh"
  ```
- [ ] One-shot 30-day backfill has been executed and at least one `review-followup` issue has been created referencing PR #18405 with the jq-in-loop finding.
  ```yaml
  verify:
    method: manual
    prompt: "Run: gh issue list --repo marcusquinn/aidevops --label review-followup --search '#18405' --state all — confirm at least one issue exists and its body cites pulse-triage.sh and Gemini's jq consolidation finding."
  ```
- [ ] `shellcheck` clean on all touched scripts.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-simplification.sh .agents/scripts/pulse-wrapper.sh .agents/scripts/pulse-dispatch-engine.sh"
  ```
- [ ] Characterization test passes (new function name registered if Option A, no regression if Option B).
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh"
  ```

## Context & Decisions

- **Why this is `tier:simple`:** the implementation is mechanical once Option A vs B is chosen. The scanner is already complete and tested — we're only adding a scheduler hook.
- **Option A preferred for consistency** with the existing `run_daily_codebase_review` which follows the exact same pattern (pulse-native function, time-gated, wired into dispatch engine). Keeping periodic-scan helpers in one place (pulse-simplification.sh) makes future maintenance easier.
- **Option B is acceptable** if the implementer finds that pulse cycle budget is too tight for even a lightweight scanner pass. The routine mechanism exists and is documented in `.agents/reference/routines.md`.
- **No new tests needed for the scanner itself** — t1386 already shipped it with tests. We're only adding a scheduler, not changing scanner behaviour.
- **Why backfill 30 days:** balance between "capture recent missed findings" and "don't create 200 issues in one go". 30 days should catch the last ~2-3 weeks of actively reviewed PRs, which is the window where Gemini/CodeRabbit reviews are most relevant. Older PRs have likely had their context drift and the findings may no longer be actionable.
- **Ruled out:**
  - *Invoking the scanner on every PR merge via a GitHub Actions workflow* — would be faster feedback but adds another CI dependency and the scanner already handles the async case correctly.
  - *Running the scanner in CI as part of the PR merge itself* — chicken-and-egg: we can't create review-followup issues before the merge completes because the dedup needs the PR to be in `state: merged`.
  - *Scanning all repos in `repos.json` rather than just `marcusquinn/aidevops`* — Option A does this already; Option B would need the routine to loop. The scanner handles one repo per invocation so this works naturally.

## Relevant Files

- `.agents/scripts/post-merge-review-scanner.sh` — the helper to schedule (already complete, ~300 lines, t1386)
- `.agents/scripts/pulse-simplification.sh:116-163` — `run_daily_codebase_review` (reference pattern)
- `.agents/scripts/pulse-wrapper.sh:433-435,489` — constants + validation pattern for CodeRabbit time gate
- `.agents/scripts/pulse-dispatch-engine.sh:761` — where `run_daily_codebase_review` is currently called
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` — function registry to update
- `.agents/reference/routines.md` — documentation for Option B routine mechanism
- Historical repro: PR #18405 review thread, Gemini Code Assist inline comment at `pulse-triage.sh:750`

## Dependencies

- **Blocked by:** none
- **Blocks:** quality feedback loop closure — without this, every Gemini/CodeRabbit inline review suggestion on merged PRs is lost
- **External:** none — scanner is already production-ready

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read `run_daily_codebase_review` pattern | 10m | Fast — already familiar |
| Decide Option A vs B | 5m | Default A unless constraint surfaces |
| Implement Option A (helper + constants + wiring) | 25m | Mechanical |
| Update characterization test | 5m | Add one function name |
| Shellcheck + characterization run | 5m | |
| One-shot 30-day backfill + verify #18405 finding captured | 10m | Check `gh issue list` output |
| **Total** | **~1h** | |
