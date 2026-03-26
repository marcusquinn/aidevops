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

Log an issue with the aidevops framework to GitHub.

**This is the recommended way to report issues.** All issues from non-collaborators are gated behind maintainer review (`needs-maintainer-review` label) regardless of how they are filed — a maintainer must approve them before the development pipeline picks them up. This command produces higher-quality reports than the web form because the AI assistant gathers diagnostics, checks for duplicates, and validates the report before submission, which helps maintainers approve issues faster.

**Arguments**: Optional issue title in quotes, e.g., `/log-issue-aidevops "Update check not working"`

## Purpose

When users encounter problems with aidevops (bugs, unexpected behavior, missing features), this command:

1. Gathers diagnostic information automatically
2. Helps the user describe the issue clearly
3. Checks for duplicate issues
4. Creates a well-structured GitHub issue on `marcusquinn/aidevops`
5. Provides the issue URL for tracking

## Workflow

### Step 1: Gather Diagnostics

Run the helper script to collect system and aidevops info:

```bash
~/.aidevops/agents/scripts/log-issue-helper.sh diagnostics
```

This collects:
- aidevops version (local and latest)
- AI assistant being used
- OS and shell info
- Current repo context
- GitHub CLI version

### Step 2: Understand the Issue

Ask the user to describe:

1. **What happened?** (the problem)
2. **What did you expect?** (expected behavior)
3. **Steps to reproduce** (if known)

If the user provided an argument, use that as the starting point for the title.

Review the current session context:
- What commands/actions led to the issue?
- Any error messages displayed?
- What was the user trying to accomplish?

### Step 3: Check for Duplicates

Search existing issues:

```bash
gh issue list -R marcusquinn/aidevops --state all --search "KEYWORDS" --limit 10
```

If potential duplicates found, show them to the user:

```text
Found similar issues:
1. #123 - "Update check fails on npm install" (open)
2. #98 - "Version mismatch after update" (closed)

Is your issue related to any of these?
1. Yes, add comment to existing issue
2. No, create new issue
3. Not sure, let me review them first
```

### Step 3.5: Architectural Alignment (enhancements and architectural changes)

For bug reports with clear reproduction steps, skip this step — bugs are observed failures and belong in the issue tracker.

For **enhancements, feature requests, and architectural changes**, evaluate the proposal against the framework's core principles before composing the issue. The model already has this knowledge — this step ensures it's applied at composition time rather than after maintainer review.

**Questions to consider:**

- **Observed failure first**: Is this addressing a failure mode that has actually occurred, or is it preemptive? Preemptive rules for unobserved failure modes are prompt bloat — every sentence in `build.txt` is processed on every turn. The bar for adding guidance is: observed failure, then minimal guidance.
- **Intelligence over determinism**: Does the proposed change add a deterministic gate, checklist, or mechanism where the model's judgment would handle it better? If the right answer depends on context, it's guidance not a rule. See `aidevops/architecture.md` "Intelligence Over Scripts".
- **Prompt cost**: Every instruction added to agent docs has a per-turn cost. Is the value of this addition worth the cost of processing it on every turn for every task? A one-line note costs less than a paragraph, but even one-liners accumulate.
- **External pattern adoption**: If the suggestion comes from comparing aidevops to another framework, consider that the other framework may have a fundamentally different philosophy. A "gap" compared to a deterministic framework may be a deliberate omission in an intelligence-first framework.

If the proposal doesn't survive these questions, discuss with the user before filing. The issue may be better as a conversation note or memory entry rather than a tracked task.

### Step 4: Compose the Issue

Build the issue with this structure:

```markdown
## Description

{User's description of the problem}

## Expected Behavior

{What should have happened}

## Steps to Reproduce

1. {Step 1}
2. {Step 2}
3. {Step 3}

## Environment

{Output from diagnostics script}

## Additional Context

{Session context, error messages, screenshots if mentioned}
```

### Step 5: Confirm Before Submitting

Present the composed issue to the user:

```text
Ready to create issue on marcusquinn/aidevops:

Title: {title}

Body:
---
{body preview, truncated if long}
---

Labels: bug (or enhancement, question, documentation)

1. Create issue
2. Edit title
3. Edit description
4. Cancel
```

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

### Step 7: Confirm Success

```text
Issue created successfully!

URL: https://github.com/marcusquinn/aidevops/issues/XXX

The maintainers will review your issue. You can:
- Add more details by commenting on the issue
- Subscribe to notifications for updates
- Reference this issue in related PRs with "Fixes #XXX"
```

## Label Selection

| Issue Type | Label |
|------------|-------|
| Something broken | `bug` |
| New feature request | `enhancement` |
| Question/help needed | `question` |
| Documentation issue | `documentation` |
| Performance problem | `performance` |

## Examples

```bash
# Interactive - will prompt for details
/log-issue-aidevops

# With title hint
/log-issue-aidevops "Update check not showing new versions"

# For feature requests
/log-issue-aidevops "Feature: Add support for GitLab"
```

## Privacy Notes

- The diagnostic info does NOT include credentials or tokens
- File paths are included (may reveal username)
- No file contents are uploaded
- User can review everything before submission

## Error Handling

If `gh` is not authenticated:

```text
GitHub CLI not authenticated. Please run:

    gh auth login

Then try /log-issue-aidevops again.
```

If network issues:

```text
Could not connect to GitHub. Please check your internet connection and try again.
```
