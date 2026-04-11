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

Non-collaborator issues are gated behind `needs-maintainer-review`. This command produces higher-quality reports than the web form — it gathers diagnostics, checks duplicates, and validates before submission.

## Workflow

### Step 1: Gather Diagnostics

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh diagnostics
```

Collects: aidevops version (local + latest), AI assistant, OS/shell, repo context, `gh` CLI version.

### Step 2: Understand the Issue

Ask the user: (1) What happened? (2) What did you expect? (3) Steps to reproduce?

Use any provided argument as the title starting point. Review session context for commands, errors, and intent.

### Step 3: Check for Duplicates

```bash
gh issue list -R marcusquinn/aidevops --state all --search "KEYWORDS" --limit 10
```

If duplicates found, present them and ask: add comment to existing / create new / review first.

### Step 3.5: Customization Routing

Before filing, check whether this is a customization need rather than a framework issue:

| User says | Route |
|-----------|-------|
| "My script edits get overwritten" | Customization — use `custom/scripts/` |
| "I want X to behave differently" | Customization — create wrapper in `custom/` |
| "I added an agent but it disappeared" | Customization — use `custom/` or `draft/` |
| "This script is broken for everyone" | Bug — file an issue |
| "The framework should support X" | Enhancement — file an issue |

If customization, explain the `custom/` directory and link to `reference/customization.md`. Do not file an issue.

### Step 3.6: Performance Issue Validation (MANDATORY)

Applies when the issue involves performance, optimization, O(n^2) claims, or "hot path" assertions (GH#17832-17835):

1. **Verify line references**: Read the cited file at the cited line. Code mismatch → REJECT.
2. **Require measurements**: "May cause O(n^2)" is not evidence. Require timing data (`time`, `hyperfine`, profiling output).
3. **Verify data scale**: A loop over 5 items on a 60-second timer is not a performance problem regardless of complexity.
4. **Detect template-driven findings**: Multiple perf issues with identical structure across files → likely unverified batch scan. Validate each independently.

If any check fails, explain why and do not file. Direct to the "Performance Optimization" issue template (mandatory evidence fields).

### Step 3.7: Architectural Alignment (enhancements only)

Skip for bugs with clear reproduction steps.

For enhancements and architectural changes, evaluate:
- **Observed failure first**: Addressing an actual failure, or preemptive? Preemptive rules are prompt bloat.
- **Intelligence over determinism**: Adding a deterministic gate where model judgment would work better?
- **Prompt cost**: Every instruction has a per-turn cost. Is the value worth it?
- **External pattern adoption**: A "gap" vs another framework may be a deliberate omission.

If the proposal doesn't survive these questions, discuss before filing — it may be better as a memory entry.

### Step 4: Compose the Issue

```markdown
## Description
{problem}

## Expected Behavior
{what should have happened}

## Steps to Reproduce
1. {step}

## Environment
{diagnostics output}

## Additional Context
{errors, session context}
```

### Step 5: Confirm and Submit

Show the user: title, body preview, label. Offer: create / edit title / edit description / cancel.

```bash
gh issue create -R marcusquinn/aidevops \
  --title "TITLE" \
  --body "$(cat <<'EOF'
BODY_CONTENT
EOF
)" \
  --label "LABEL"
```

Output the issue URL. Note: user can add comments, subscribe, or reference with `Fixes #NNN`.

## Label Selection

| Issue Type | Label |
|------------|-------|
| Something broken | `bug` |
| New feature request | `enhancement` |
| Question/help needed | `question` |
| Documentation issue | `documentation` |
| Performance problem | `performance` |

## Privacy

Diagnostics do NOT include credentials or tokens. File paths included (may reveal username). No file contents uploaded. User reviews everything before submission.

## Error Handling

- `gh` not authenticated → prompt `gh auth login`, retry.
- Network failure → prompt user to check connection, retry.
