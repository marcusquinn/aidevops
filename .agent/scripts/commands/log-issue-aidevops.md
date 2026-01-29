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

**Arguments**: Optional issue title in quotes, e.g., `/log-issue-aidevops "Update check not working"`

## Purpose

When users encounter problems with aidevops (bugs, unexpected behavior, missing features), this command:

1. Gathers diagnostic information automatically
2. Helps the user describe the issue clearly
3. Creates a GitHub issue on `marcusquinn/aidevops`
4. Provides the issue URL for tracking

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
