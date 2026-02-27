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
# 2. Search by task ID if we have one
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
    gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "status:in-progress" 2>/dev/null || true
    for STALE in "status:available" "status:queued" "status:claimed"; do
      gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label "$STALE" 2>/dev/null || true
    done
  fi
fi
```

**Label vocabulary** — use these status labels at the appropriate lifecycle points:

| Label | When to set | Set by |
|-------|-------------|--------|
| `status:available` | Issue created, no assignee | issue-sync-helper (automated) |
| `status:queued` | Task queued for dispatch | Supervisor (contextual) |
| `status:claimed` | Task has assignee, not yet started | issue-sync-helper (automated) |
| `status:in-progress` | Worker actively coding | **Worker (this step)** |
| `status:in-review` | PR opened, awaiting review | **Worker (Step 4)** |
| `status:blocked` | Task has unresolved blockers | Worker or supervisor (contextual) |
| `status:done` | PR merged | sync-on-pr-merge workflow (automated) |
| `status:verify-failed` | Post-merge verification failed | Worker (contextual) |
| `status:needs-testing` | Code merged, needs manual testing | Worker (contextual) |
| `dispatched:{model}` | Worker started on task | **Worker (Step 0.7)** |

Only `status:available`, `status:claimed`, and `status:done` are fully automated. All other transitions are set contextually by the agent that best understands the current state. When setting a new status label, always remove the prior status labels to keep exactly one active.

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

### Step 2: Start Full Loop

**Supervisor dispatch** (headless mode - t174):

When dispatched by the supervisor, `--headless` is passed automatically. This suppresses all interactive prompts, prevents TODO.md edits, and ensures clean exit on errors. You can also set `FULL_LOOP_HEADLESS=true` as an environment variable.

**Recommended: Background mode** (avoids timeout issues):

```bash
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS" --background
```

This starts the loop in the background and returns immediately. Use these commands to monitor:

```bash
# Check status
~/.aidevops/agents/scripts/full-loop-helper.sh status

# View logs
~/.aidevops/agents/scripts/full-loop-helper.sh logs

# Cancel if needed
~/.aidevops/agents/scripts/full-loop-helper.sh cancel
```

**Foreground mode** (may timeout in MCP tools):

```bash
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS"
```

This will:
1. Initialize the Ralph loop for task development
2. Set up state tracking in `.agents/loop-state/full-loop.local.md`
3. Begin iterating on the task

**Note**: Foreground mode may timeout when called via MCP Bash tool (default 120s timeout). Use `--background` for long-running tasks.

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
5. **README gate passed** (see below)
6. Conventional commits used (for auto-changelog)
7. **Headless rules observed** (see below)

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

**Headless dispatch rules (MANDATORY for supervisor-dispatched workers - t158/t174):**

When running as a headless worker (dispatched by the supervisor via `opencode run` or `Claude -p`), the `--headless` flag is passed automatically. The full-loop-helper.sh script enforces these rules:

1. **NEVER prompt for user input** - There is no human at the terminal. Use the uncertainty decision framework (rule 7) to decide whether to proceed or exit.

2. **Do NOT edit TODO.md** - Put notes in commit messages or PR body instead. See `workflows/plans.md` "Worker TODO.md Restriction".

3. **Do NOT edit shared planning files** - Files like `todo/PLANS.md`, `todo/tasks/*` are managed by the supervisor. Workers should only modify files relevant to their assigned task.

4. **Handle auth failures gracefully** - If `gh auth status` fails, the script retries 3 times then exits cleanly with a clear error for supervisor evaluation. Do NOT retry indefinitely.

5. **Exit cleanly on unrecoverable errors** - If you cannot complete the task (missing dependencies, permissions, etc.), emit a clear error message and exit. Do not loop forever.

6. **git pull --rebase before push** (t174) - The PR create phase automatically runs `git pull --rebase` to sync with any remote changes before pushing, avoiding push rejections.

7. **Uncertainty decision framework** (t176) - When facing ambiguity, use this decision tree:

   **PROCEED autonomously** (document decision in commit message):
   - Multiple valid approaches exist but all achieve the goal — pick the simplest
   - Style/naming choices are ambiguous — follow existing codebase conventions
   - Task description is slightly vague but intent is clear from context
   - Choosing between equivalent libraries/patterns — match project precedent
   - Minor scope questions (e.g., fix adjacent issue?) — stay focused on assigned task

   **EXIT cleanly** (include clear explanation in output):
   - Task description contradicts what you find in the codebase
   - Completing the task requires breaking changes to public APIs or shared interfaces
   - The task is already done or obsolete
   - Required dependencies, credentials, or services are missing and cannot be inferred
   - The task requires architectural decisions that affect other tasks
   - Unsure whether to create vs modify a file, and getting it wrong risks data loss

   When proceeding, document the choice: `feat: add retry logic (chose exponential backoff — matches existing patterns)`
   When exiting, be specific: `BLOCKED: Task says 'update auth endpoint' but 3 exist (JWT, OAuth, API key). Need clarification.`

8. **Worker time budget and progressive PR (MANDATORY for headless workers):**

   Workers MUST be aware of elapsed time and act progressively to avoid the systemic pattern of running 3-9 hours without producing any PR. The goal is: **always produce a PR, even if partial.**

   **Time checkpoints:**

   - **At 45 minutes:** Self-check — have you made meaningful progress? If you're stuck on a dependency (missing schema, unmerged prerequisite, missing API), do NOT keep trying to work around it. Instead:
     1. Commit what you have (even if incomplete)
     2. Exit cleanly with: `BLOCKED: dependency not available — <specific dependency>. Partial work committed on branch.`
     3. The supervisor will re-dispatch when the dependency merges.

   - **At 90 minutes:** If you have working code (even partial), begin the PR phase immediately:
     1. Commit all work with `feat: partial implementation of <task> (time budget)`
     2. Create a draft PR with `gh pr create --draft` explaining what's done and what remains
     3. File subtask issues for remaining work
     4. Exit cleanly — a partial PR is infinitely more valuable than no PR after 3 hours

   - **At 120 minutes (hard limit):** Stop all implementation work. PR whatever you have:
     1. If you have ANY commits: create a draft PR with a clear "What's done / What remains" section
     2. If you have NO commits (completely stuck): exit with a detailed `BLOCKED:` message explaining exactly what prevented progress
     3. Never exceed 2 hours without either a PR or a clear exit message

   **Dependency detection (early exit):** At the START of task development, before writing any code, verify that the task's prerequisites exist in the codebase:
   - If the task references tables, APIs, or schemas from another task, check if they exist: `rg 'tableName\|functionName' --type ts`
   - If the task says "blocked-by: tXXX" in TODO.md or the issue body, check if tXXX's PR is merged: `gh pr list --state merged --search "tXXX"`
   - If prerequisites are missing, exit immediately with `BLOCKED: prerequisite tXXX not merged — <specific missing item>`. Do not attempt to implement the missing prerequisite yourself.

   **Why this matters:** 5 workers running 4+ hours each with no PRs = 20+ hours of wasted compute. A worker that exits after 10 minutes with "BLOCKED: t030 not merged, profile table doesn't exist" saves 3h 50m and gives the supervisor actionable information.

   **Push/PR failure recovery (#2452 pattern):** If `git push` or `gh pr create` fails, do NOT silently continue working. This is the root cause of workers that commit code but never produce a PR — they hit a push failure (auth, branch protection, network) and keep iterating on code instead of addressing the failure. On any push or PR creation failure:
   1. Log the exact error message
   2. Retry once after `git pull --rebase origin main` (handles diverged branches)
   3. If retry fails, exit immediately with: `BLOCKED: push/PR creation failed — <exact error>. Commits exist on local branch <branch-name> in worktree <path>.`
   4. Do NOT continue implementing code after a push failure — the work is unrecoverable without a PR

9. **Cross-repo routing** — If you discover mid-task that the fix belongs in a different repo (e.g., working in awardsapp but the bug is in an aidevops framework script), do NOT create tasks or TODO entries in the current repo. Instead, file a GitHub issue in the correct repo:

   ```bash
   gh issue create --repo <owner/correct-repo> --title "<description>" \
     --body "Discovered while working on <current-task> in <current-repo>. <details>"
   ```

   **If creating TODOs/PLANS in another repo** (e.g., adding a TODO to `~/Git/aidevops/TODO.md` while working in awardsapp): always commit and push them immediately so the issue-sync workflow picks them up. Uncommitted TODOs are invisible to the supervisor and issue-sync.

   ```bash
   git -C ~/Git/<target-repo> add TODO.md todo/PLANS.md
   git -C ~/Git/<target-repo> commit -m "chore: add t{id} TODO from <current-repo> session"
   git -C ~/Git/<target-repo> push origin main
   ```

   Then continue with your assigned task in the current repo. The pulse supervisor will pick up the cross-repo issue on its next cycle. This prevents framework-level work from being tracked in app repos and vice versa.

10. **Issue-task alignment (MANDATORY)** — Before linking your PR to an issue or claiming a task, verify your work matches the issue's actual description. Workers have hijacked issues by using a task ID for completely unrelated work (e.g., PR "Fix ShellCheck noise" closed issue "Add local dev row to build-plus.md" because both used t1344).

    **Before creating a PR that references an issue:**
    - Read the issue title and body: `gh issue view <number> --repo <owner/repo>`
    - Verify your PR's changes actually implement what the issue describes
    - If your work is unrelated to the issue, create a new issue for your work instead

    **If you discover your assigned task is already done or the issue was closed:**
    - Check if the closing PR actually implemented the task (read the PR diff)
    - If the PR was unrelated work that incorrectly closed the issue, reopen it and comment explaining the mismatch
    - Do NOT silently reuse a task ID for different work

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

After task completion, the loop automatically:

1. **Preflight**: Runs quality checks, auto-fixes issues
2. **PR Create**: Verifies `gh auth`, rebases onto `origin/main`, pushes branch, creates PR with proper title/body
   **Issue linkage in PR body (MANDATORY):** The PR body MUST include `Closes #NNN` (or `Fixes`/`Resolves`) for every related issue — this is the ONLY mechanism that creates a GitHub PR-issue link. Before writing the PR body, search for ALL open issues related to your task: `gh issue list --state open --search "<task description keywords>"`. Issues may exist under different title formats (e.g., `coderabbit: Fix X` and `t1234: Fix X` for the same task). Include closing keywords for every match. A comment like "Resolved by PR #NNN" does NOT create a link — only closing keywords in the PR body do.
3. **Label Update**: Update linked issue to `status:in-review` (see below)
4. **PR Review**: Monitors CI checks and review status
5. **Merge**: Squash merge (without `--delete-branch` when in worktree)
6. **Issue Closing Comment**: Post a summary comment on linked issues (see below)
7. **Worktree Cleanup**: Return to main repo, pull, clean merged worktrees
8. **Postflight**: Verifies release health after merge
9. **Deploy**: Runs `setup.sh --non-interactive` (aidevops repos only)

**Issue-state guard before any label/comment modification (t1343 — MANDATORY):**

Before modifying any linked issue (adding labels, posting comments, or changing state), ALWAYS check its current state. Use fail-closed semantics — only proceed when state is explicitly `OPEN`:

```bash
for ISSUE_NUM in $LINKED_ISSUES; do
  ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  if [[ "$ISSUE_STATE" != "OPEN" ]]; then
    # Fail closed: skip on CLOSED, UNKNOWN, empty, or any non-OPEN state.
    # CLOSED = already resolved by another session. UNKNOWN = gh failure/timeout.
    # Either way, do NOT modify — modifications on ambiguous state cause noise.
    echo "[t1343] Skipping issue #$ISSUE_NUM — state is $ISSUE_STATE (not OPEN)"
    continue
  fi
  # ... proceed with label/comment updates only for OPEN issues
done
```

This prevents the race condition where a worker's delayed lifecycle transition overwrites a supervisor's correct closure. If the issue is already closed with a merged PR, any further label changes (`needs-review`, `status:in-review`, etc.) are noise. The fail-closed design also protects against transient `gh` failures — if the state check fails, modifications are skipped rather than allowed.

**PR lookup fallback (t1343):** When checking whether a merged PR exists for the current task (e.g., before deciding to flag an issue as `needs-review`), do NOT rely solely on your session's local state. Use the fallback chain from `planning-detail.md` "PR Lookup Fallback" — check local state first, then `gh pr list --state merged --search "<task_id>"`, then issue timeline cross-references. If ANY source confirms a merged PR, the task has PR evidence.

**Issue label update on PR create — `status:in-review`:**

After creating the PR, update linked issues to `status:in-review`. Extract linked issue numbers from the PR body (`Fixes #NNN`, `Closes #NNN`, `Resolves #NNN`) and update each:

```bash
for ISSUE_NUM in $LINKED_ISSUES; do
  # t1343: Check issue state before modifying — fail closed (only modify if explicitly OPEN)
  ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  if [[ "$ISSUE_STATE" != "OPEN" ]]; then
    echo "[t1343] Skipping issue #$ISSUE_NUM — state is $ISSUE_STATE (not OPEN)"
    continue
  fi
  gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "status:in-review" 2>/dev/null || true
  gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label "status:in-progress" 2>/dev/null || true
done
```

The `status:done` transition is handled automatically by the `sync-on-pr-merge` workflow when the PR merges — workers do not need to set it.

**Issue closing comment (MANDATORY — do NOT skip):**

After the PR merges, post a closing comment on every linked GitHub issue. This preserves the context that would otherwise die with the worker session. The comment is the permanent record of what was done.

Find linked issues from the PR body (`Fixes #NNN`, `Closes #NNN`, `Resolves #NNN`):

```bash
# Get the PR body and extract linked issue numbers
PR_BODY=$(gh pr view <PR_NUMBER> --repo <owner/repo> --json body -q .body)
# Parse "Fixes #123", "Closes #456", "Resolves #789" patterns
```

For each linked issue, post a comment with this structure:

```bash
gh issue comment <ISSUE_NUMBER> --repo <owner/repo> --body "$(cat <<'COMMENT'
## Completed via PR #<PR_NUMBER>

**What was done:**
- <bullet list of what was implemented/fixed>

**How it was tested:**
- <what tests were run, what was verified>

**Key decisions:**
- <any non-obvious choices made and why>

**Files changed:**
- `path/to/file.ext` — <what changed and why>

**Blockers encountered:**
- <any issues hit during implementation, and how they were resolved>
- None (if clean)

**Follow-up needs:**
- <anything that should be done next but was out of scope>
- None (if complete)
COMMENT
)"
```

**Rules:**
- Every section must have at least one bullet (use "None" if nothing to report)
- Be specific — "fixed the bug" is useless; "fixed race condition in worktree creation by adding `sleep 2` between dispatches" is useful
- Include file paths with brief descriptions so future workers can find the changes
- If the task was dispatched by the supervisor, include the original dispatch description for traceability
- This is a gate: do NOT emit `FULL_LOOP_COMPLETE` until closing comments are posted

**Worktree cleanup after merge:**

```bash
# When in a worktree, merge without --delete-branch
gh pr merge --squash

# Then clean up from main repo
cd ~/Git/$(basename "$PWD" | cut -d. -f1)  # Return to main repo
git pull origin main                        # Get merged changes
wt prune                                    # Clean merged worktrees
```

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

### README Updates

README updates are enforced by the **README gate** in Step 3 completion criteria. You do NOT need to include "and update README" in your prompt - the gate catches it automatically.

When the gate triggers, update README.md with:
- New feature documentation
- Usage examples
- API endpoint descriptions
- Configuration options

### Changelog (Auto-Generated)

The release workflow auto-generates CHANGELOG.md from conventional commits. Use proper commit prefixes during task development:

| Prefix | Changelog Section | Example |
|--------|-------------------|---------|
| `feat:` | Added | `feat: add JWT authentication` |
| `fix:` | Fixed | `fix: resolve token expiration bug` |
| `docs:` | Changed | `docs: update API documentation` |
| `perf:` | Changed | `perf: optimize database queries` |
| `refactor:` | Changed | `refactor: simplify auth middleware` |
| `chore:` | (excluded) | `chore: update dependencies` |

See `workflows/changelog.md` for format details.

## OpenProse Orchestration

For complex multi-phase workflows, consider expressing the full loop in OpenProse DSL:

```prose
agent developer:
  model: opus
  prompt: "You are a senior developer"

# Phase 1: Task Development
loop until **task is complete** (max: 50):
  session: developer
    prompt: "Implement the feature, run tests, fix issues"

# Phase 2: Preflight (parallel quality checks)
parallel:
  lint = session "Run linters and fix issues"
  types = session "Check types and fix issues"
  tests = session "Run tests and fix failures"

if **any checks failed**:
  loop until **all checks pass** (max: 5):
    session "Fix remaining issues"
      context: { lint, types, tests }

# Phase 3: PR Creation
let pr = session "Create pull request with gh pr create --fill"

# Phase 4: PR Review Loop
loop until **PR is merged** (max: 20):
  parallel:
    ci = session "Check CI status"
    review = session "Check review status"

  if **CI failed**:
    session "Fix CI issues and push"

  if **changes requested**:
    session "Evaluate review feedback: verify factual claims against runtime/docs/project conventions, dismiss incorrect suggestions with evidence, address valid ones, then push"

# Phase 5: Postflight
session "Verify release health"
```

See `tools/ai-orchestration/openprose.md` for full OpenProse documentation.

## Related

- `workflows/ralph-loop.md` - Ralph loop technique details
- `workflows/preflight.md` - Pre-commit quality checks
- `workflows/pr.md` - PR creation workflow
- `workflows/postflight.md` - Post-release verification
- `workflows/changelog.md` - Changelog format and validation
- `tools/ai-orchestration/openprose.md` - OpenProse DSL for multi-agent orchestration
