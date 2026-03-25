---
description: Start end-to-end development loop (task → preflight → PR → postflight → deploy)
agent: Build+
mode: subagent
---

Start a full development loop that chains all phases from task implementation to deployment.

Task/Prompt: $ARGUMENTS

## Step 0: Resolve Task ID and Set Session Title

**IMPORTANT**: Before proceeding, extract the first positional argument from `$ARGUMENTS` (ignoring flags like `--max-task-iterations`). Check if it matches the task ID pattern `t\d+` (e.g., `t061`).

**Supervisor dispatch format (t158)**: When dispatched by the supervisor, the prompt may include the task description inline: `/full-loop t061 -- Fix the login bug`. If `$ARGUMENTS` contains ` -- `, everything after ` -- ` is the task description provided by the supervisor. Use it directly instead of looking up TODO.md.

If the first argument is a task ID (e.g., `t061`):

1. Extract the task ID and resolve its description using this priority chain:

   ```bash
   # Extract first argument (the task ID)
   TASK_ID=$(echo "$ARGUMENTS" | awk '{print $1}')

   # Priority 1: Inline description from supervisor dispatch (after " -- ")
   TASK_DESC=$(echo "$ARGUMENTS" | sed -n 's/.*-- //p')

   # Priority 2: Look up from TODO.md
   if [[ -z "$TASK_DESC" ]]; then
       TASK_DESC=$(grep -E "^- \[( |x|-)\] $TASK_ID " TODO.md 2>/dev/null | head -1 | sed -E 's/^- \[( |x|-)\] [^ ]* //')
   fi

   # Priority 3: Query GitHub issues (for dynamically-created tasks not yet in TODO.md)
   if [[ -z "$TASK_DESC" ]]; then
       TASK_DESC=$(gh issue list --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
           --search "$TASK_ID" --json title -q '.[0].title' 2>/dev/null || echo "")
   fi
   ```

2. Set the session title using the `session-rename` MCP tool:

   ```text
   # Call the session-rename tool with the title parameter
   session-rename(title: "t061: Improve session title to include task description")
   ```

   - Good: `"t061: Improve session title to include task description"`
   - Bad: `"Full loop development for t061"`

3. **Fallback**: If `$TASK_DESC` is still empty after all lookups, use: `"t061: (task not found)"`

4. Store the full task description for use in subsequent steps.

If the first argument is NOT a task ID (it's a description):
- Use the description directly for the session title
- Call `session-rename` tool with a concise version if the description is very long (truncate to ~60 chars)
- **Extract issue number if present (#2452 fix):** If `$ARGUMENTS` contains `issue #NNN` or `Issue #NNN`, extract the issue number for the OPEN state check in Step 0.6. Store it as `$ISSUE_NUM` so the state check fires even without a task ID:

  ```bash
  # Extract issue number from supervisor dispatch format: "Implement issue #2452 ..."
  # Use portable sed (POSIX) — grep -oP is GNU-only and fails on macOS/BSD
  ISSUE_NUM=$(echo "$ARGUMENTS" | sed -En 's/.*[Ii][Ss][Ss][Uu][Ee][[:space:]]*#*([0-9]+).*/\1/p' | head -1)
  ```

**Example session titles:**
- Task ID `t061` with description "Improve session title format" → `"t061: Improve session title format"`
- Task ID `t061` with supervisor inline `-- Fix login bug` → `"t061: Fix login bug"`
- Task ID `t999` not found anywhere → `"t999: (task not found)"`
- Description "Add JWT authentication" → `"Add JWT authentication"`

## Full Loop Phases

```text
Claim → Branch Setup → Task Development → Preflight → PR Create → PR Review → Postflight → Deploy
```

## Lifecycle Completeness Gate (t5096 + GH#5317 — MANDATORY)

**Two distinct failure modes exist. Both are equally fatal:**

**Failure mode 1 (GH#5317):** Worker exits after implementation WITHOUT committing or creating a PR. Files left uncommitted in the worktree. The supervisor cannot detect or recover uncommitted work. This is the earlier failure — it happens before PR creation.

**Failure mode 2 (GH#5096):** Worker exits after PR creation WITHOUT completing the post-PR lifecycle (review, merge, release, cleanup). The PR sits unmerged indefinitely.

**The full lifecycle in order — do NOT skip any step:**

0. **Commit+PR gate (GH#5317)** — At the end of implementation in Step 3, verify all changes are committed (`git status --porcelain` is empty) and create/confirm the PR. Only after this gate passes may `TASK_COMPLETE` be emitted. (`TASK_COMPLETE` now means: implementation done + all changes committed + PR exists.)
1. **Review bot gate** — wait for CodeRabbit/Gemini/Copilot reviews (poll up to 10 min)
2. **Address critical findings** — fix security/critical issues from bot reviews
3. **Merge** — `gh pr merge --squash` (without `--delete-branch` in worktrees)
4. **Auto-release** — bump patch version + create GitHub release (aidevops repo only)
5. **Issue closing comment** — post a structured comment on every linked issue
6. **Worktree cleanup** — return to main, pull, prune merged worktrees

**Do NOT emit `FULL_LOOP_COMPLETE` until step 0 through step 6 are done.** If you stop at implementation without a PR, or stop at PR creation without merging, the task is incomplete. (`TASK_COMPLETE` = implementation + commit/PR gate complete; `FULL_LOOP_COMPLETE` = all 7 steps complete.)

This gate applies regardless of how you were dispatched (pulse, `/runners`, bare `opencode run`, or interactive). See Step 4 below for the full details of each phase.

## Workflow

### Step 0.5: Claim Task (t1017)

If the first argument is a task ID (`t\d+`), claim it before starting work. This prevents two agents (or a human and an agent) from working on the same task concurrently.

```bash
# Claim the task — adds assignee:<identity> started:<ISO> to TODO.md task line
# Uses git pull → grep assignee: → add fields → commit + push
# Race protection: git push rejection = someone else claimed first
```

**Exit codes:**
- `0` - Claimed successfully (or already claimed by you) — proceed
- `1` - Claimed by someone else — **STOP, do not start work**

**If claim fails** (task is claimed by another contributor):
- In interactive mode: inform the user and stop
- In headless mode: exit cleanly with `BLOCKED: task claimed by assignee:{name}`

**Skip claim when:**
- The first argument is not a task ID (it's a description)
- The `--no-claim` flag is passed

### Step 0.6: Update Issue Label — `status:in-progress`

After claiming the task, update the linked GitHub issue label to reflect that work has started. This gives at-a-glance visibility into which tasks have active workers.

```bash
# Find the linked issue number — check multiple sources (#2452 fix):
# 1. Already extracted from "issue #NNN" in arguments (Step 0)
# 2. Extract from TODO.md ref:GH#NNN (authoritative — set during task creation)
if [[ -z "$ISSUE_NUM" || "$ISSUE_NUM" == "null" ]] && [[ -n "$TASK_ID" ]]; then
  ISSUE_NUM=$(grep -E "^\s*-\s*\[.\]\s*${TASK_ID}[[:space:]]" TODO.md 2>/dev/null \
    | sed -En 's/.*ref:GH#([0-9]+).*/\1/p' | head -1)
fi
# 3. Fallback: search GitHub issues by task ID prefix
if [[ -z "$ISSUE_NUM" || "$ISSUE_NUM" == "null" ]] && [[ -n "$TASK_ID" ]]; then
  ISSUE_NUM=$(gh issue list --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" \
    --state open --search "${TASK_ID}:" --json number,title --limit 5 \
    | jq -r --arg tid "$TASK_ID" '[.[] | select(.title | test("^" + $tid + "[.:\\s]"))] | .[0].number // empty' 2>/dev/null || true)
fi

if [[ -n "$ISSUE_NUM" && "$ISSUE_NUM" != "null" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

  # t1343 + #2452: Check issue state — if CLOSED, abort the entire worker session.
  # This is the worker-side defense against being dispatched for a closed issue.
  # The supervisor checks OPEN state before dispatch (scripts/commands/pulse.md Step 3), but if
  # the issue was closed between dispatch and worker startup, catch it here.
  ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  if [[ "$ISSUE_STATE" != "OPEN" ]]; then
    echo "[t1343/#2452] Issue #$ISSUE_NUM state is $ISSUE_STATE (not OPEN) — aborting worker"
    echo "ABORTED: Issue #$ISSUE_NUM is $ISSUE_STATE. Nothing to implement."
    # In headless mode, exit cleanly. In interactive mode, inform the user.
    exit 0
  else
    # Self-assign to prevent duplicate work by other runners/humans
    WORKER_USER=$(gh api user --jq '.login' 2>/dev/null || whoami)
    gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-assignee "$WORKER_USER" --add-label "status:in-progress" 2>/dev/null || true
    for STALE in "status:available" "status:queued" "status:claimed"; do
      gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label "$STALE" 2>/dev/null || true
    done
  fi
fi
```

**Label and assignment lifecycle** — labels and GitHub issue assignees work together to coordinate work across multiple machines and contributors:

| Label | Assignee | When | Set by |
|-------|----------|------|--------|
| `status:available` | none | Issue created or recovered from stale state | issue-sync-helper, or pulse (recovery) |
| `status:queued` | runner user | Pulse dispatches a worker | **Supervisor pulse** |
| `status:in-progress` | worker user | Worker starts coding | **Worker (this step)** |
| `status:in-review` | worker user | PR opened, awaiting review | **Worker (Step 4)** |
| `status:blocked` | unchanged | Task has unresolved blockers | Worker or supervisor (contextual) |
| `status:done` | unchanged | PR merged | sync-on-pr-merge workflow (automated) |
| `status:verify-failed` | unchanged | Post-merge verification failed | Worker (contextual) |
| `status:needs-testing` | unchanged | Code merged, needs manual testing | Worker (contextual) |
| `dispatched:{model}` | unchanged | Worker started on task | **Worker (Step 0.7)** |

**Assignment rules:**
- The pulse assigns the issue to the runner user at dispatch time (before the worker starts). This prevents other runners/humans from picking up the same issue.
- The worker self-assigns in this step as defense-in-depth (covers manual dispatch, interactive sessions).
- If a worker crashes and the issue goes stale (3+ hours with no PR), the pulse recovers it: relabels to `status:available`, unassigns, and comments explaining the recovery.

**Consistency rule:** When setting a new status label, always remove the prior status labels to keep exactly one active.

### Step 0.7: Label Dispatch Model — `dispatched:{model}`

After setting `status:in-progress`, tag the issue with the model running this worker. This provides observability into which model solved each task — essential for cost/quality analysis.

**Detect the current model** from the system prompt or environment. The model name appears in the system prompt as "You are powered by the model named X" or via `ANTHROPIC_MODEL` / `CLAUDE_MODEL` environment variables. Map to a short label:

| Model contains | Label |
|----------------|-------|
| `opus` | `dispatched:opus` |
| `sonnet` | `dispatched:sonnet` |
| `haiku` | `dispatched:haiku` |
| unknown | skip labeling |

```bash
# Detect model — check env vars first, fall back to known model identity
MODEL_SHORT=""
for VAR in "$ANTHROPIC_MODEL" "$CLAUDE_MODEL"; do
  case "$VAR" in
    *opus*)   MODEL_SHORT="opus" ;;
    *sonnet*) MODEL_SHORT="sonnet" ;;
    *haiku*)  MODEL_SHORT="haiku" ;;
  esac
  [[ -n "$MODEL_SHORT" ]] && break
done

# Fallback: the agent knows its own model from the system prompt.
# If env vars are empty, set MODEL_SHORT based on your model identity.
# Example: if you are claude-opus-4-6, set MODEL_SHORT="opus"

if [[ -n "$MODEL_SHORT" && -n "$ISSUE_NUM" && "$ISSUE_NUM" != "null" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

  # Remove stale dispatched:* labels so attribution is unambiguous
  for OLD in "dispatched:opus" "dispatched:sonnet" "dispatched:haiku"; do
    if [[ "$OLD" != "dispatched:${MODEL_SHORT}" ]]; then
      if ! gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label "$OLD" 2>/dev/null; then
        : # Label not present — expected, not an error
      fi
    fi
  done

  # Create the label if it doesn't exist yet
  if ! LABEL_ERR=$(gh label create "dispatched:${MODEL_SHORT}" --repo "$REPO" \
    --description "Task dispatched to ${MODEL_SHORT} model" --color "1D76DB" 2>&1); then
    # "already exists" is expected — only warn on other failures
    if [[ "$LABEL_ERR" != *"already exists"* ]]; then
      echo "[dispatch-label] Warning: label create failed for dispatched:${MODEL_SHORT} on ${REPO}: ${LABEL_ERR}" >&2
    fi
  fi

  if ! EDIT_ERR=$(gh issue edit "$ISSUE_NUM" --repo "$REPO" \
    --add-label "dispatched:${MODEL_SHORT}" 2>&1); then
    echo "[dispatch-label] Warning: could not add dispatched:${MODEL_SHORT} to issue #${ISSUE_NUM} on ${REPO}: ${EDIT_ERR}" >&2
  fi
fi
```

**For interactive sessions** (not headless dispatch): If you are working on a task interactively and the issue exists, apply the label based on your own model identity. This ensures all task work is attributed, not just headless dispatches.

### Step 0.8: Task Decomposition Check (t1408, t1408.2)

Before claiming and starting work, classify the task. Skip if `--no-decompose` is passed or subtasks already exist in TODO.md.

```bash
DECOMPOSE_HELPER="$HOME/.aidevops/agents/scripts/task-decompose-helper.sh"
if [[ -x "$DECOMPOSE_HELPER" && -n "$TASK_ID" ]]; then
  HAS_SUBS=$(/bin/bash "$DECOMPOSE_HELPER" has-subtasks "$TASK_ID") || HAS_SUBS="false"
  if [[ "$HAS_SUBS" == "false" ]]; then
    CLASSIFY=$(/bin/bash "$DECOMPOSE_HELPER" classify "$TASK_DESC" --depth 0) || CLASSIFY=""
    TASK_KIND=$(echo "$CLASSIFY" | jq -r '.kind // "atomic"' || echo "atomic")
  fi
fi
```

**If atomic (default):** Proceed to Step 0.5. Most tasks are atomic; the classify call costs ~$0.001.

**If composite — interactive:** Show decomposition tree, ask Y/n/edit. On confirm: create child task IDs via `claim-task-id.sh`, add `blocked-by:` edges, create briefs, label parent `status:blocked`.

**If composite — headless:** Auto-decompose, create child tasks and briefs, exit with: `DECOMPOSED: task $TASK_ID split into $SUBTASK_COUNT subtasks ($CHILD_IDS). Parent blocked. Children queued for dispatch.`

**Depth limit:** `DECOMPOSE_MAX_DEPTH` env var (default: 3). At depth 3+, always treat as atomic.

### Step 1: Auto-Branch Setup

The loop automatically handles branch setup when on main/master:

```bash
# Run pre-edit check in loop mode with task description
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "$ARGUMENTS"
```

**Exit codes:**
- `0` - Already on feature branch OR docs-only task (proceed)
- `1` - Interactive mode fallback (shouldn't happen in loop)
- `2` - Code task on main (auto-create worktree)

**Auto-decision logic:**
- **Docs-only tasks** (README, CHANGELOG, docs/, typos): Stay on main
- **Code tasks** (features, fixes, refactors, enhancements): Auto-create worktree

**Detection keywords:**
- Docs-only: `readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`
- Code (overrides docs): `feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`

**When worktree is needed:**

```bash
# Generate branch name from task (sanitized, truncated to 40 chars)
branch_name=$(echo "$ARGUMENTS" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)

# Preferred: Use Worktrunk (wt) if installed
wt switch -c "feature/$branch_name"

# Fallback: Use worktree-helper.sh if wt not available
~/.aidevops/agents/scripts/worktree-helper.sh add "feature/$branch_name"
# Continue in new worktree directory
```

Also verify:
- **Clean working directory**: Uncommitted changes should be committed or stashed
- **Git remote configured**: Need to push and create PR

```bash
git status --short
```

### Step 1.5: Operation Verification (t1364.3)

Before high-stakes operations (production deploys, DB migrations, force pushes, secret rotation), invoke cross-provider model verification to catch single-model hallucinations.

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh --verify-op "git push --force origin main"
# Or: source verify-operation-helper.sh; risk=$(check_operation "cmd"); result=$(verify_operation "cmd" "$risk")
```

| Risk | Examples | Action |
|------|----------|--------|
| critical | Force push to main, `rm -rf /`, drop DB, production deploy, expose secrets | Block (headless) / confirm (interactive) |
| high | Hard reset, branch deletion, DB migration, npm publish | Verify via cross-provider model call |
| moderate | Package installs, config/permission changes | Log only |
| low | Code edits, docs, tests | No verification |

Config env vars: `VERIFY_ENABLED=true`, `VERIFY_POLICY=warn` (warn/block/skip), `VERIFY_TIMEOUT=30`, `VERIFY_MODEL=haiku`.

### Step 1.7: Parse Lineage Context (t1408.3)

If the dispatch prompt contains a `TASK LINEAGE:` block, parse it at session start to understand your scope within a task hierarchy.

**Worker rules when lineage is present:**

1. **Scope boundary** — Only implement what's marked `<-- THIS TASK`. Stop if you find yourself implementing a sibling's work.
2. **Stub dependencies** — For types/APIs a sibling will create, define minimal stubs and document them in the PR body under "Cross-task stubs".
3. **No sibling work** — Each sibling has its own worker, branch, and PR. Overlapping implementations cause merge conflicts.
4. **PR body lineage section** — Include parent, this task, and siblings with task IDs.
5. **Blocked by sibling** — If a hard dependency (not just a stub) is unmet, exit: `BLOCKED: This task (tX.Y) requires <item> from sibling tX.Z, which has not been merged yet.`

### Step 2: Start Full Loop

When dispatched by the supervisor, `--headless` is passed automatically (suppresses prompts, prevents TODO.md edits, ensures clean exit). Also settable via `FULL_LOOP_HEADLESS=true`.

```bash
# Recommended: background mode (avoids MCP Bash 120s timeout)
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS" --background

# Monitor: status | logs | cancel
~/.aidevops/agents/scripts/full-loop-helper.sh status
~/.aidevops/agents/scripts/full-loop-helper.sh logs
~/.aidevops/agents/scripts/full-loop-helper.sh cancel
```

### Step 3: Task Development (Ralph Loop)

The AI will iterate on the task until outputting:

```text
<promise>TASK_COMPLETE</promise>
```

**Completion criteria (ALL must be satisfied before emitting TASK_COMPLETE):**

1. All requirements implemented — list each as [DONE], if any are [TODO] keep working
2. Tests passing (if applicable)
3. Code quality acceptable (lint, shellcheck, type-check)
4. **Generalization check** — solution works for varying inputs, not just current state
5. **README gate passed** — required if task adds/changes user-facing features (see below)
6. Conventional commits used — required for all commits (enables auto-changelog)
7. **Headless rules observed** (see below)
8. **Actionable finding coverage** — if this task produces a multi-finding report (audit/review/scan), every deferred actionable finding has a tracked follow-up (`task_id` + issue ref)
9. **Commit+PR gate (GH#5317 — MANDATORY)** — ALL changes committed and a PR exists before emitting `TASK_COMPLETE`. This is the #1 failure mode: workers print "Implementation complete" and exit without committing or creating a PR, leaving files uncommitted in the worktree. Run this check immediately before emitting `TASK_COMPLETE`:

   ```bash
   # Verify no uncommitted changes remain
   UNCOMMITTED=$(git status --porcelain | wc -l | tr -d ' ')
   if [[ "$UNCOMMITTED" -gt 0 ]]; then
     echo "[GH#5317] Uncommitted changes detected — committing before TASK_COMPLETE"
     git add -A
     git commit -m "feat: complete implementation (GH#5317 commit gate)"
   fi

   # Verify a PR exists (create one if not)
   CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   if [[ "$CURRENT_BRANCH" != "main" && "$CURRENT_BRANCH" != "master" ]]; then
     git push -u origin HEAD 2>/dev/null || git push origin HEAD
     if ! gh pr view >/dev/null 2>&1; then
       echo "[GH#5317] No PR found — creating PR before TASK_COMPLETE"
       # PR creation happens in Step 4 — proceed there now, do NOT emit TASK_COMPLETE yet
     fi
   fi
   ```

   **Do NOT emit `TASK_COMPLETE` if there are uncommitted changes or no PR.** Fix the gap first, then emit the signal. `TASK_COMPLETE` means "implementation done AND PR exists" — not just "implementation done".

**Actionable finding coverage procedure (mandatory when output includes multiple findings):**

1. Build an actionable list for deferred items (one line per finding) in a temp file using this format:

   ```text
   severity|title|details
   ```

2. Convert that list into tracked tasks and issues with:

   ```bash
   ~/.aidevops/agents/scripts/findings-to-tasks-helper.sh create \
     --input <path/to/actionable-findings.txt> \
     --repo-path "$(git rev-parse --show-toplevel)" \
     --source <audit|review|seo|accessibility|performance>
   ```

3. Include proof in your PR body or final report:
   - `actionable_findings_total=<N>`
   - `fixed_in_pr=<N>`
   - `deferred_tasks_created=<N>`
   - `coverage=100%`

If coverage is below 100%, the task is not complete.

**Parallelism rule (t217)**: When your task involves multiple independent operations (reading several files, running lint + typecheck + tests, researching separate modules), use the Task tool to run them concurrently in a single message — not one at a time. Serial execution of independent work wastes wall-clock time proportional to the number of subtasks. See `tools/ai-assistants/headless-dispatch.md` "Worker Efficiency Protocol" point 5 for criteria and examples.

**Replanning rule**: If your approach isn't working after a reasonable attempt, step back
and try a fundamentally different strategy before giving up. A fresh approach often
succeeds where incremental fixes to a broken one fail.

**CI failure debugging (t1334)**: When a task involves fixing CI failures or a PR has
failing checks, ALWAYS read the CI logs first before attempting any code changes:

```bash
# 1. Identify the failing job
gh pr checks <PR_NUMBER> --repo <owner/repo>

# 2. Get the run ID and read failure logs
gh run view <RUN_ID> --repo <owner/repo> --log | grep -iE 'FAIL|Error.*spec|expect.*received'

# 3. Identify the EXACT test name, file, and line number from the error
```

This prevents context exhaustion from blind debugging. Workers that skip this step
waste entire sessions guessing at root causes. Common pitfalls:
- Testing the wrong DOM element (e.g., `<main>` vs its child `<div>`)
- Assuming infrastructure issues (OOM, timeouts) when the test itself is wrong
- Not checking if another PR (e.g., a CI investigation PR) already identified the fix

**Quality-debt blast radius cap (t1422 — MANDATORY for quality-debt tasks):**

PRs for `quality-debt`/`simplification-debt` tasks must touch **at most 5 files** (hard cap, not guideline). Large batch PRs (10-69 files) conflict with every other PR in flight — 63%+ of open PRs become `CONFLICTING`. Small PRs merge cleanly in any order.

If the issue covers more than 5 files: implement the first 5 (by severity), create the PR, then file follow-up issues for the rest. This rule does NOT apply to feature PRs, bug fixes, or refactors.

```bash
CHANGED_FILES=$(git diff --name-only origin/main | wc -l | tr -d ' ')
[[ "$CHANGED_FILES" -gt 5 ]] && echo "[t1422] WARNING: split into multiple PRs"
```

**Headless dispatch rules (MANDATORY for supervisor-dispatched workers - t158/t174):**

When running as a headless worker, `--headless` is passed automatically. Rules:

1. **NEVER prompt for user input** — use the uncertainty framework (rule 7) to proceed or exit.
2. **Do NOT edit TODO.md or shared planning files** (`todo/PLANS.md`, `todo/tasks/*`) — use commit messages and PR body instead. See `workflows/plans.md` "Worker TODO.md Restriction".
3. **Handle auth failures gracefully** — retry `gh auth status` 3 times then exit cleanly. Do NOT retry indefinitely.
4. **Exit cleanly on unrecoverable errors** — emit a clear message and exit. Do not loop forever.
5. **git pull --rebase before push** (t174) — avoids push rejections from diverged branches.

6. **Uncertainty decision framework** (t176):

   **PROCEED autonomously** (document in commit message): multiple valid approaches → pick simplest; style/naming ambiguity → follow codebase conventions; vague description with clear intent → interpret reasonably; minor scope questions → stay focused.

   **EXIT cleanly** (specific explanation): task contradicts codebase; requires breaking API changes; task already done/obsolete; missing dependencies/credentials; architectural decisions affecting other tasks; create-vs-modify ambiguity with data loss risk.

   Examples: `feat: add retry logic (chose exponential backoff — matches existing patterns)` / `BLOCKED: Task says 'update auth endpoint' but 3 exist (JWT, OAuth, API key). Need clarification.`

7. **Worker time budget and progressive PR (MANDATORY):** Always produce a PR, even if partial.

   - **At 45 min:** Self-check. If stuck on a dependency, commit what you have and exit: `BLOCKED: dependency not available — <specific>. Partial work committed on branch.`
   - **At 90 min:** Begin PR phase immediately. Commit with `feat: partial implementation of <task> (time budget)`, create draft PR, file subtask issues for remaining work.
   - **At 120 min (hard limit):** Stop implementation. If ANY commits exist: create draft PR with "What's done / What remains". If NO commits: exit with detailed `BLOCKED:` message. Never exceed 2 hours without a PR or clear exit.

   **Dependency detection (early exit):** Before writing any code, verify prerequisites exist. Check `gh pr list --state merged --search "tXXX"` for `blocked-by:` tasks. If missing, exit immediately: `BLOCKED: prerequisite tXXX not merged — <specific missing item>`. Why: 5 workers × 4h with no PRs = 20h wasted compute.

   **Push/PR failure recovery (#2452):** On any `git push` or `gh pr create` failure: log the error, retry once after `git pull --rebase origin main`, then exit: `BLOCKED: push/PR creation failed — <exact error>. Commits on branch <name> in worktree <path>.` Do NOT continue implementing after a push failure.

8. **Cross-repo routing** — If the fix belongs in a different repo, file a GitHub issue there (always allowed) and stop code changes if that repo is outside `PULSE_SCOPE_REPOS`:

   ```bash
   if [[ -n "${PULSE_SCOPE_REPOS:-}" ]]; then
     if ! echo ",$PULSE_SCOPE_REPOS," | grep -qF ",$TARGET_SLUG,"; then
       gh issue create --repo "$TARGET_SLUG" --title "TITLE" --body "..."
       echo "BLOCKED: target repo out of pulse scope; issue filed — stopping."
       exit 0
     fi
   fi
   ```

   If creating TODOs in another repo, commit and push them immediately — uncommitted TODOs are invisible to the supervisor.

9. **Issue-task alignment (MANDATORY)** — Before linking your PR to an issue, read the issue (`gh issue view <number>`) and verify your changes implement what it describes. Workers have hijacked issues by reusing task IDs for unrelated work (e.g., t1344 incident). If your work is unrelated, create a new issue. If the issue was incorrectly closed by an unrelated PR, reopen it with a comment.

**README gate (MANDATORY - do NOT skip):**

Before emitting `TASK_COMPLETE`, answer this decision tree:

1. Did this task add a new feature, tool, API, command, or config option? → **Update README.md**
2. Did this task change existing user-facing behavior? → **Update README.md**
3. Is this a pure refactor, bugfix with no behavior change, or internal-only change? → **SKIP**

If README update is needed:

```bash
# For any repo: use targeted section updates
/readme --sections "usage"  # or relevant section

# For aidevops repo: also check if counts are stale
~/.aidevops/agents/scripts/readme-helper.sh check
# If stale, run: readme-helper.sh update --apply
```

**Do NOT emit TASK_COMPLETE until README is current.** This is a gate, not a suggestion. The t099 Neural-Chromium task was merged without a README update because this gate was advisory - it is now mandatory.

### Step 4: Automatic Phase Progression

After `TASK_COMPLETE` (which requires the commit+PR gate from Step 3 criterion 9 to have already passed), the loop continues through the post-PR lifecycle:

1. **Preflight**: Runs quality checks, auto-fixes issues
2. **PR Create**: Verifies `gh auth`, rebases onto `origin/main`, pushes branch, creates PR with proper title/body. **Note:** If the commit+PR gate in Step 3 already created the PR, this step confirms it exists and ensures the PR body has proper issue linkage — it does not create a duplicate.
   **Issue linkage in PR body (MANDATORY):** The PR body MUST include `Closes #NNN` (or `Fixes`/`Resolves`) for every related issue — this is the ONLY mechanism that creates a GitHub PR-issue link.

   **Primary source: use `$ISSUE_NUM` from Step 0.** The issue number resolved during dispatch (from arguments, TODO.md `ref:GH#`, or `gh issue list` by task ID) is the authoritative source. Always include `Closes #$ISSUE_NUM` in the PR body. Do NOT re-search by keywords — keyword search across issues with similar titles (e.g., multiple subtasks of the same parent) returns wrong matches.

   **Secondary: search for additional related issues only.** After including the primary `$ISSUE_NUM`, optionally search for duplicate or related issues (e.g., CodeRabbit-created issues for the same task): `gh issue list --state open --search "<task_id>:"`. Only add `Closes` for issues whose title starts with the same task ID prefix. Never add `Closes` for an issue you found by keyword similarity alone — verify the task ID matches.

   A comment like "Resolved by PR #NNN" does NOT create a link — only closing keywords in the PR body do. **Caution:** GitHub parses `Closes #NNN` anywhere in the PR body — including explanatory prose. If describing a bug that involved wrong issue linkage, use backtick-escaped references (`` `Closes #NNN` ``) or rephrase to avoid the pattern. PR #2512 itself closed the wrong issue because its description mentioned `Closes #2498` when explaining the original bug.
3. **Label Update**: Update linked issue to `status:in-review` (see below)
4. **PR Review**: Monitors CI checks and review status
5. **Review Bot Gate (t1382)**: Wait for AI review bots before merge (see below)
6. **Merge**: Squash merge (without `--delete-branch` when in worktree)
7. **Auto-Release**: Bump patch version + create GitHub release (aidevops repo only — see below)
8. **Issue Closing Comment**: Post a summary comment on linked issues, including release version (see below)
9. **Worktree Cleanup**: Return to main repo, pull, clean merged worktrees
10. **Postflight**: Verifies release health after merge
11. **Deploy**: Runs `setup.sh --non-interactive` (aidevops repos only)

**Issue-state guard before any label/comment modification (t1343 — MANDATORY):**

Before modifying any linked issue, ALWAYS check its state. Use fail-closed semantics — only proceed when state is explicitly `OPEN`. This prevents race conditions where a worker's delayed transition overwrites a supervisor's correct closure, and protects against transient `gh` failures.

```bash
for ISSUE_NUM in $LINKED_ISSUES; do
  ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  if [[ "$ISSUE_STATE" != "OPEN" ]]; then
    echo "[t1343] Skipping issue #$ISSUE_NUM — state is $ISSUE_STATE (not OPEN)"
    continue
  fi
  # proceed with label/comment updates only for OPEN issues
done
```

**PR lookup fallback (t1343):** Do NOT rely solely on session-local state. Check: local state → `gh pr list --state merged --search "<task_id>"` → issue timeline. If ANY source confirms a merged PR, the task has PR evidence.

**Issue label update on PR create — `status:in-review`:**

After creating the PR, extract linked issue numbers from the PR body (`Fixes/Closes/Resolves #NNN`) and for each OPEN issue:

```bash
gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "status:in-review" 2>/dev/null || true
gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label "status:in-progress" 2>/dev/null || true
```

The `status:done` transition is handled automatically by the `sync-on-pr-merge` workflow — workers do not need to set it.

**Review Bot Gate (t1382 — MANDATORY before merge):**

Wait for AI review bots before merging. Three enforcement layers: CI (`review-bot-gate.yml` required check), agent (this rule), branch protection.

```bash
RESULT=$(~/.aidevops/agents/scripts/review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO")
# Returns: PASS | WAITING | SKIP
```

- **WAITING**: Poll every 60s up to 10 min (`REVIEW_BOT_WAIT_MAX=600`). Interactive: ask user. Headless: proceed with warning (CI gate is the hard stop).
- **PASS**: Read reviews, address critical/security findings before merging.
- **SKIP**: PR has `skip-review-gate` label (docs-only PRs, repos without bots).

Known bots: `coderabbitai` (1-3 min), `gemini-code-assist[bot]` (2-5 min), `augment-code[bot]` (2-4 min), `copilot[bot]` (1-3 min). Incident: PR #1 on aidevops-cloudron-app merged before bots posted, losing all security findings.

**Auto-release after merge (aidevops repo only — MANDATORY):**

After merging on `marcusquinn/aidevops`, cut a patch release so auto-update users receive the fix immediately.

```bash
REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
if [[ "$REPO_SLUG" == "marcusquinn/aidevops" ]]; then
  CANONICAL_DIR="${REPO_ROOT%%.*}"  # Strip worktree suffix
  git -C "$CANONICAL_DIR" pull origin main
  (cd "$CANONICAL_DIR" && "$HOME/.aidevops/agents/scripts/version-manager.sh" bump patch)
  NEW_VERSION=$(cat "$CANONICAL_DIR/VERSION")
  git -C "$CANONICAL_DIR" add -A
  git -C "$CANONICAL_DIR" commit -m "chore(release): bump version to v${NEW_VERSION}"
  git -C "$CANONICAL_DIR" push origin main
  git -C "$CANONICAL_DIR" tag "v${NEW_VERSION}" && git -C "$CANONICAL_DIR" push origin "v${NEW_VERSION}"
  gh release create "v${NEW_VERSION}" --repo "$REPO_SLUG" \
    --title "v${NEW_VERSION} - AI DevOps Framework" --generate-notes
  "$CANONICAL_DIR/setup.sh" --non-interactive || true
fi
```

Patch (not minor/major) because workers cannot determine release significance — the maintainer cuts minor/major manually when appropriate.

**Issue closing comment (MANDATORY — do NOT skip):**

After the PR merges, post a closing comment on every linked issue. This is the permanent record of what was done — context that would otherwise die with the worker session.

```bash
gh issue comment <ISSUE_NUMBER> --repo <owner/repo> --body "$(cat <<'COMMENT'
## Completed via PR #<PR_NUMBER>

**What was done:** <bullet list>
**How it was tested:** <what was verified>
**Key decisions:** <non-obvious choices and why>
**Files changed:** `path/to/file.ext` — <what changed and why>
**Blockers encountered:** <issues hit and how resolved, or None>
**Follow-up needs:** <out-of-scope items, or None>
**Released in:** v<VERSION> — run `aidevops update` to get this fix.
COMMENT
)"
```

Rules: every section needs at least one bullet (use "None"); be specific (not "fixed the bug" — "fixed race condition in worktree creation by adding `sleep 2`"); include file paths; omit "Released in" for non-aidevops repos. This is a gate: do NOT emit `FULL_LOOP_COMPLETE` until closing comments are posted.

**Worktree cleanup after merge:**

See [`worktree-cleanup.md`](worktree-cleanup.md) for the full cleanup sequence (merge without `--delete-branch`, pull main, prune worktrees). Key constraint: never pass `--delete-branch` to `gh pr merge` when running from inside a worktree.

### Step 5: Human Decision Points

> **Note**: In `--headless` mode (t174), the loop never pauses for human input. It proceeds autonomously through all phases and exits cleanly if blocked.

The loop pauses for human input at (interactive mode only):

| Point | When | Action Required |
|-------|------|-----------------|
| Merge approval | If repo requires human approval | Approve PR in GitHub |
| Rollback | If postflight detects issues | Decide whether to rollback |
| Scope change | If task evolves beyond original | Confirm new scope |

### Step 6: Completion

When all phases complete:

```text
<promise>FULL_LOOP_COMPLETE</promise>
```

## Commands

```bash
# Start new loop
/full-loop "Implement feature X with tests"

# Check status
~/.aidevops/agents/scripts/full-loop-helper.sh status

# Resume after interruption
~/.aidevops/agents/scripts/full-loop-helper.sh resume

# Cancel loop
~/.aidevops/agents/scripts/full-loop-helper.sh cancel
```

## Options

Pass options after the prompt:

```bash
/full-loop "Fix bug Y" --max-task-iterations 30 --skip-postflight
```

| Option | Description |
|--------|-------------|
| `--background`, `--bg` | Run in background (recommended for long tasks) |
| `--headless` | Fully headless worker mode (no prompts, no TODO.md edits) |
| `--max-task-iterations N` | Max iterations for task (default: 50) |
| `--max-preflight-iterations N` | Max iterations for preflight (default: 5) |
| `--max-pr-iterations N` | Max iterations for PR review (default: 20) |
| `--skip-preflight` | Skip preflight checks |
| `--skip-postflight` | Skip postflight monitoring |
| `--no-auto-pr` | Pause for manual PR creation |
| `--no-auto-deploy` | Don't auto-run setup.sh |

## Examples

```bash
# Basic feature implementation (background mode recommended)
/full-loop "Add user authentication with JWT tokens" --background

# Foreground mode (may timeout for long tasks)
/full-loop "Add user authentication with JWT tokens"

# Bug fix with limited iterations
/full-loop "Fix memory leak in connection pool" --max-task-iterations 20 --background

# Skip postflight for quick iteration
/full-loop "Update documentation" --skip-postflight

# Manual PR creation
/full-loop "Refactor database layer" --no-auto-pr --background

# View background loop progress
~/.aidevops/agents/scripts/full-loop-helper.sh logs
```

## Documentation & Changelog

README updates are enforced by the **README gate** in Step 3 — no need to include "update README" in your prompt.

CHANGELOG.md is auto-generated from conventional commits: `feat:` (Added), `fix:` (Fixed), `docs:/perf:/refactor:` (Changed), `chore:` (excluded). See `workflows/changelog.md`.

## OpenProse Orchestration

For complex multi-phase workflows, the full loop can be expressed in OpenProse DSL. See `tools/ai-orchestration/openprose.md` for documentation and examples.

## Related

- `workflows/ralph-loop.md` - Ralph loop technique details
- `workflows/preflight.md` - Pre-commit quality checks
- `workflows/pr.md` - PR creation workflow
- `workflows/postflight.md` - Post-release verification
- `workflows/changelog.md` - Changelog format and validation
- `tools/ai-orchestration/openprose.md` - OpenProse DSL for multi-agent orchestration
