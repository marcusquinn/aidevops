---
description: Log an issue with aidevops to GitHub for the maintainers to address
agent: Build+
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Log an issue with the aidevops framework to GitHub.

**Arguments**: Optional title hint, e.g., `/log-issue-aidevops "Update check not working"`

All issues from non-collaborators are gated behind `needs-maintainer-review` — a maintainer must approve before the pipeline picks them up. This command produces higher-quality reports than the web form because it gathers diagnostics, checks duplicates, and validates before submission.

## Before Composing

**Enumerate every manual workaround you applied in the current session.** Each is a candidate fix for a systemic problem:

- File the highest-ROI workaround as the primary issue.
- File the rest as sibling issues with `See-also: #<this-issue>` cross-references.
- Add a `## Workarounds Applied` section to the primary issue body listing all workarounds.

**Workaround examples and their fix routes:**

| Workaround applied | Likely systemic fix |
|---|---|
| Applied `complexity-bump-ok` label to bypass a false-positive gate | Gate needs refinement for specific false-positive class |
| `sudo aidevops approve` to unblock auto-approved issue stuck in NMR | NMR classification logic has a gap |
| Manually ran `pre-edit-check.sh` because hook didn't fire | Hook installation or detection issue |
| `gh pr edit --base main` after an `origin:interactive` PR stacked on a feature branch | Stacked-PR retarget logic needs extending to grandchildren |

## Pre-composition Checks (MANDATORY)

Before composing any framework-bug report, run these 5 checks. They are shared with t2409 (`workflows/brief.md` "Pre-composition checks") — referenced here by pointer, not duplicated.

1. **Memory recall**: `memory-helper.sh recall --query "<symptom-keywords>" --limit 5` — surface accumulated lessons before re-diagnosing a known issue. A lesson that says "same error, fixed in t2108" saves 30+ minutes.

2. **Discovery pass (t2046)**: Check if the bug was already fixed:

   ```bash
   git log --since="1 week ago" --oneline -- <suspect-files>
   gh pr list --state merged --search "<keywords>" --limit 5
   gh pr list --state open --search "<keywords>" --limit 5
   ```

   If a recent commit touches the exact file/function you're investigating, verify the bug still reproduces on HEAD before filing. Stale symptoms from a pre-deploy state (see `prompts/build.txt` section 10) are not bugs — close the investigation.

3. **File:line verification**: For every file reference in the brief, run `git ls-files <path>` or `sed -n "<line>p" <path>` to confirm the reference exists and the content matches the claim. Phantom line refs force the worker to spend the first hour re-locating the code (GH#17832-17835).

4. **Tier disqualifier check**: Framework bugs are usually `tier:standard`. Cross-check the draft brief against `reference/task-taxonomy.md` "Tier Assignment Validation" disqualifiers before assigning `tier:simple`. Default to `tier:standard` when uncertain.

5. **Self-assignment awareness**: If filing via `gh_create_issue` with the `auto-dispatch` label, plan to `gh issue edit N --remove-assignee <user>` immediately after — the wrapper currently self-assigns (t2406/#19991). Alternatively, omit `auto-dispatch` until ready to hand off.

## Workflow

### Step 1: Gather Diagnostics

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh diagnostics
```

Collects: aidevops version (local + latest), AI assistant, OS/shell, repo context, `gh` CLI version.

### Step 2: Understand the Issue

Ask the user:
1. What happened?
2. What did you expect?
3. Steps to reproduce (if known)?

Use any provided argument as the title starting point. Review session context for commands, errors, and intent.

### Step 2.5: Evidence Attribution and Reproducer (framework bugs only)

For bugs with an observable failure mode, the observing session has a live reproducer context that vanishes at session end. Capture it now:

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh prompt-reproducer
```

This outputs the section template. Collect and include in the issue body:

1. **Symptom**: exact command that exhibited the bug + full terminal output
2. **Expected**: what should have happened
3. **Causal code**: `git blame <file> -L <line>,<line>` output or commit SHA suspected to have introduced the regression
4. **Call-site sweep**: `rg "<function-or-pattern>" .agents/scripts/` to enumerate all affected locations

Store the collected data under a `## Reproducer` section in the issue body (included in the compose template in Step 4).

A brief filed without a Reproducer section forces the worker to spend 30-60 min reconstructing the failure mode from scratch — the exact time cost described in GH#20008.

### Step 2.6: Workaround Enumeration

Before composing, enumerate every manual workaround you applied during the current session that relates to this bug. For each workaround:

- What was the workaround command or action?
- Does the workaround reveal a gap that should be a separate fix?
- Can it be automated so no future session needs it?

**For each workaround that has a clear systemic fix:**

- File it as a separate issue with `See-also: #<this-issue>` in its body, OR
- Add it to the `## Siblings` section of the current brief

### Step 3: Check for Duplicates

**3a — Keyword search (catches semantic duplicates):**

```bash
gh issue list -R marcusquinn/aidevops --state all --search "KEYWORDS" --limit 10
```

If duplicates found, present them and ask: add comment to existing / create new / review first.

> **Note on indexing lag:** GitHub's search index has a 2–10 second lag after an issue is created. This step catches semantic matches in existing issues but cannot detect an identical issue filed seconds ago in the same session. The deterministic fingerprint check at Step 5.5 closes that gap — do not skip it.

### Step 3.5: Customization Routing

Before filing, check whether this is a customization need rather than a framework issue:

| User says | Likely route |
|-----------|-------------|
| "My script edits get overwritten" | Customization — use `~/.aidevops/agents/custom/scripts/` |
| "I want X to behave differently" | Customization — create a wrapper in `custom/` |
| "I added an agent but it disappeared" | Customization — use `custom/` or `draft/` (root agents are overwritten) |
| "This script is broken for everyone" | Bug — file an issue |
| "The framework should support X" | Enhancement — file an issue (maintainers assess fit) |

If the need is customization, explain the `custom/` directory and link to `reference/customization.md`. Do not file an issue.

### Step 3.6: Performance Issue Validation (MANDATORY for performance/optimization claims)

If the issue involves performance, optimization, O(n^2) claims, or "hot path" assertions:

1. **Verify line references**: Read the cited file at the cited line number. If the code at that line does not match the claim, REJECT the issue. Do not file issues with hallucinated line numbers.
2. **Require measurements**: "May cause O(n^2)" is not evidence. Require actual timing data (`time`, `hyperfine`, profiling output). No measurements = no issue.
3. **Verify data scale**: Check how many items the loop actually processes and how often it runs. A loop over 5 items on a 60-second timer is not a performance problem regardless of algorithmic complexity.
4. **Check for template-driven findings**: If the user or AI is filing multiple performance issues with identical structure ("nested loops", "O(n^2)", "hot path") across different files, this is likely a batch code scan without verification. Validate each independently.

If any check fails, explain why and do not file the issue. Direct the user to the "Performance Optimization" issue template which requires mandatory evidence fields.

### Step 3.7: Architectural Alignment (enhancements only)

Skip for bugs with clear reproduction steps — bugs are observed failures and belong in the tracker.

For enhancements, feature requests, and architectural changes, evaluate against:

- **Observed failure first**: Is this addressing an actual failure, or preemptive? Preemptive rules are prompt bloat.
- **Intelligence over determinism**: Does this add a deterministic gate where model judgment would work better?
- **Prompt cost**: Every instruction has a per-turn cost. Is the value worth it?
- **External pattern adoption**: A "gap" vs another framework may be a deliberate omission in an intelligence-first design.

If the proposal doesn't survive these questions, discuss before filing — it may be better as a memory entry.

### Step 4: Compose the Issue

For framework bugs, use this expanded template that includes Evidence Attribution and Reproducer sections:

```markdown
## Description

{problem}

## Expected Behavior

{what should have happened}

## Reproducer

**Symptom command**:

```
{exact command that exhibited the bug}
```

**Actual output**:

```
{full terminal output}
```

**Expected output**:

{what should have happened}

**Causal code** (if identified):

```bash
{git blame output or commit SHA}
```

## Steps to Reproduce

1. {step}

## Workarounds Applied

{list each workaround used during the observing session}

## Environment

{diagnostics output}

## Additional Context

{errors, session context}
```

For non-bug reports (enhancements, questions), use the shorter template without Reproducer and Workarounds sections:

```markdown
## Description

{problem or request}

## Expected Behavior

{what should happen}

## Steps to Reproduce

1. {step, if applicable}

## Environment

{diagnostics output}

## Additional Context

{errors, session context}
```

### Step 5: Confirm Before Submitting

Show the user: title, body preview, label. Offer: create / edit title / edit description / cancel.

### Step 5.5: Fingerprint Pre-Check (deterministic dedup)

Before creating the issue, run a fingerprint check against this session and prior sessions.
This check is not subject to GitHub's search index lag — it reads a local state file.

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh check-fingerprint "EXACT_TITLE" "EXACT_BODY"
```

Replace `EXACT_TITLE` and `EXACT_BODY` with the title and body from Step 4/5.

**If output is `OK`**: proceed to Step 6.

**If output starts with `DUPLICATE:NNN:SECONDS`** (e.g., `DUPLICATE:20312:8`):
- **Do NOT create a new issue.** The body hash matches issue #NNN filed NNN seconds ago.
- Inform the user: "Issue #NNN was already filed NNN seconds ago with an identical body."
- Offer the user:
  1. View the existing issue: `gh issue view NNN -R marcusquinn/aidevops`
  2. Add a comment to the existing issue (if new information has emerged)
  3. Proceed with a new issue only if the user explicitly confirms a different scope is intended

This step is **MANDATORY** — it is the primary guard against the indexing-lag race window
documented in GH#20322. Do not skip it even if Step 3 returned no results.

### Step 6: Create the Issue

```bash
gh issue create -R marcusquinn/aidevops \
  --title "TITLE" \
  --body "$(cat <<'EOF'
BODY_CONTENT
EOF
)" \
  --label "LABEL"
```

### Step 6.5: Record Fingerprint

After a successful `gh issue create`, extract the issue number from the URL and record the fingerprint
so future sessions can detect this as a duplicate:

```bash
# Extract issue number from the URL (e.g., https://github.com/marcusquinn/aidevops/issues/20312 → 20312)
ISSUE_NUMBER=<number from created issue URL>
~/.aidevops/agents/scripts/log-issue-helper.sh record-fingerprint "EXACT_TITLE" "EXACT_BODY" "$ISSUE_NUMBER"
```

This writes to `~/.aidevops/state/log-issue-fingerprints.jsonl`. On transient failures where
`gh issue create` may have succeeded server-side, re-running the command will be caught by the
Step 5.5 fingerprint check within the dedup window (default: 120 seconds, configurable via
`LOG_ISSUE_DEDUP_WINDOW_SECONDS`).

### Step 7: Confirm Success

Output the issue URL. Note: user can add comments, subscribe to notifications, or reference with `Fixes #NNN`.

## Label Selection

| Issue Type | Label |
|------------|-------|
| Something broken | `bug` |
| New feature request | `enhancement` |
| Question/help needed | `question` |
| Documentation issue | `documentation` |
| Performance problem | `performance` |

## Privacy

Diagnostics do NOT include credentials or tokens. File paths are included (may reveal username). No file contents uploaded. User reviews everything before submission.

## Error Handling

- `gh` not authenticated: prompt `gh auth login`, then retry.
- Network failure: prompt user to check connection and retry.
