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

All issues from non-collaborators are gated behind `needs-maintainer-review`. This command produces higher-quality reports than the web form by gathering diagnostics, checking duplicates, and validating before submission.

## Workflow

### Step 1: Gather Diagnostics

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh diagnostics
```

Collects: aidevops version (local + latest), AI assistant, OS/shell, repo context, `gh` CLI version.

### Step 2: Understand the Issue

Ask the user: (1) What happened? (2) What did you expect? (3) Steps to reproduce?

Use any provided argument as the title starting point. Review session context for commands, errors, and intent.

### Step 3: Pre-Filing Checks

**Duplicates:**

```bash
gh issue list -R marcusquinn/aidevops --state all --search "KEYWORDS" --limit 10
```

If duplicates found, ask: add comment to existing / create new / review first.

**Customization routing** — check before filing:

| User says | Route |
|-----------|-------|
| "My script edits get overwritten" | `~/.aidevops/agents/custom/scripts/` — see `reference/customization.md` |
| "I want X to behave differently" | `custom/` wrapper |
| "I added an agent but it disappeared" | `custom/` or `draft/` |
| "This script is broken for everyone" | Bug — file an issue |
| "The framework should support X" | Enhancement — file an issue |

**Performance claims (MANDATORY):** Verify line references match actual code, require timing measurements (`time`/`hyperfine`), check data scale. No measurements = no issue. Direct to "Performance Optimization" issue template.

**Enhancements only — architectural alignment:**
- Observed failure first (preemptive rules = prompt bloat)
- Intelligence over determinism (model judgment vs. deterministic gate)
- Prompt cost vs. value
- If proposal doesn't survive these, discuss before filing.

### Step 4: Compose and Confirm

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

Show the user: title, body preview, label. Offer: create / edit title / edit description / cancel.

### Step 5: Create the Issue

```bash
gh issue create -R marcusquinn/aidevops \
  --title "TITLE" \
  --body "$(cat <<'EOF'
BODY_CONTENT
EOF
)" \
  --label "LABEL"
```

Labels: `bug` (broken), `enhancement` (new feature), `question` (help), `documentation`, `performance`.

Output the issue URL. User can add comments or reference with `Fixes #NNN`.

## Privacy

Diagnostics do NOT include credentials or tokens. File paths are included (may reveal username). User reviews everything before submission.

## Error Handling

- `gh` not authenticated: `gh auth login`, then retry.
- Network failure: check connection and retry.
