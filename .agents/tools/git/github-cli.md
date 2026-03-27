---
description: GitHub CLI (gh) for repos, PRs, issues, and actions
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# GitHub CLI Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

```bash
gh auth login -s workflow   # Login (include workflow scope)
gh auth status              # Verify scopes
gh auth refresh -s workflow # Add workflow scope to existing token
gh auth token               # Get token for scripts

gh repo list / create / clone / view / fork
gh issue list / create / view / close
gh pr list / create / view / merge
gh release list / create / view / download
gh run list / view / watch / rerun
gh api repos/owner/repo     # Direct API access
```

**Required scope: `workflow`** — Without it, pushes/merges of PRs modifying `.github/workflows/` fail with "refusing to allow an OAuth App to create or update workflow without workflow scope". The framework checks for this at setup and before push.

**Multi-account**: `gh auth switch` to change accounts; `gh auth status` to list all.

<!-- AI-CONTEXT-END -->

## Authentication

```bash
gh auth login -s workflow        # Interactive login (stores token in keyring)
gh auth refresh -s workflow      # Add workflow scope to existing token
gh auth status                   # Check auth + verify 'workflow' in Token scopes
gh auth token                    # Get token for use in scripts ($GITHUB_TOKEN / $GH_TOKEN)
gh auth switch                   # Switch between accounts
```

Authentication is stored in your system keyring — no `GITHUB_TOKEN` env var needed for normal `gh` operations.

## Core Commands

```bash
# Repos
gh repo create my-repo --public --description "My project"
gh repo clone owner/repo
gh repo view owner/repo
gh repo fork owner/repo

# Issues
gh issue list --state open --label bug
gh issue create --title "Bug report" --body "Description"
gh issue view 123
gh issue close 123

# Pull Requests
gh pr create --title "Feature X" --body "Description"
gh pr create --fill          # Auto-fill from commits
gh pr view 123
gh pr merge 123 --squash     # Also: --merge, --rebase

# Releases
gh release create v1.2.3 --generate-notes
gh release create v1.2.3 --draft --generate-notes
gh release list / view / download v1.2.3

# Workflow runs
gh run list
gh run view 123456
gh run watch
gh run rerun 123456 --failed

# API
gh api repos/owner/repo/issues
gh api repos/owner/repo/issues -f title="Bug" -f body="Details"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "not logged in" | `gh auth login -s workflow` |
| "token expired" | `gh auth refresh` |
| Wrong account | `gh auth switch` |
| "refusing to allow...workflow scope" / push fails on `.github/workflows/` | `gh auth refresh -s workflow` |
| Need token for script | `export GH_TOKEN=$(gh auth token)` |

## External Repo Submissions

When filing issues or PRs on repos you don't maintain, bots may auto-close non-conforming submissions. Check guidelines first.

### Discovering Templates

```bash
# Issue templates
gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE/ --jq '.[].name' || true
gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE/bug-report.yml \
  --jq '.content' | base64 -d || true

# CONTRIBUTING.md
gh api repos/{owner}/{repo}/contents/CONTRIBUTING.md \
  --jq '.content' | base64 -d || true

# PR template
gh api repos/{owner}/{repo}/contents/.github/PULL_REQUEST_TEMPLATE.md \
  --jq '.content' | base64 -d || true
gh api repos/{owner}/{repo}/contents/.github/PULL_REQUEST_TEMPLATE/ \
  --jq '.[].name' || true
```

### Mapping YAML Form Templates to Markdown

GitHub YAML issue forms (`.yml`) render as structured forms in the web UI. When submitted, they produce markdown with `### Label` headers matching each field's `label:` attribute. Replicate this structure when using `gh issue create`.

**Example YAML form fields → compliant issue body:**

```yaml
body:
  - type: textarea
    attributes:
      label: Describe the bug
  - type: textarea
    attributes:
      label: Steps to reproduce
  - type: input
    attributes:
      label: Version
```

```markdown
### Describe the bug

The application crashes when clicking Save after editing a profile.

### Steps to reproduce

1. Navigate to Settings > Profile
2. Change the display name
3. Click Save

### Version

v2.4.1
```

**Key rules:**

- Each `label:` value becomes a `### Label` header — match exactly (case-sensitive)
- Every required field must have a non-empty section below its header
- `type: checkboxes` → `- [x]` / `- [ ]` lists; `type: dropdown` → selected option text; `type: input` → plain text
- Fields with `required: true` must not be blank — compliance bots check this

### Handling Auto-Close Bots

1. Read the bot's closing comment — it explains what's missing
2. Check the close window (some bots give 2 hours to fix before closing)
3. Resubmit with the correct format rather than editing the closed issue
4. Some bots use AI (e.g., Claude/Sonnet) to verify compliance — partial matches may not pass

### Pre-Submission Checklist

1. Is this repo in `~/.config/aidevops/repos.json`? If yes, skip these checks (it's ours)
2. Does `.github/ISSUE_TEMPLATE/` exist? If yes, use the matching template
3. Does `CONTRIBUTING.md` exist? If yes, follow its guidelines (CLA, branch naming, etc.)
4. For PRs: check if they require signed commits, specific branch targets, or linked issues

## See Also

- `lumen.md` — AI-powered visual diffs, commit message generation, and PR review
- `conflict-resolution.md` — Git conflict resolution strategies
- `worktrunk.md` — Worktree management for parallel work
