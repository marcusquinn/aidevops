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
gh auth status              # Verify scopes + list accounts
gh auth refresh -s workflow # Add workflow scope to existing token
gh auth token               # Get token for scripts
gh auth switch              # Switch between accounts

gh repo list / create / clone / view / fork
gh issue list / create / view / close
gh pr list / create / view / merge
gh release list / create / view / download
gh run list / view / watch / rerun
gh api repos/owner/repo     # Direct API access
```

**Required scope: `workflow`** — Without it, pushes modifying `.github/workflows/` fail with "refusing to allow...workflow scope". Fix: `gh auth refresh -s workflow`.

<!-- AI-CONTEXT-END -->

## Core Commands

```bash
# Repos
gh repo create my-repo --public --description "My project"
gh repo clone owner/repo && gh repo view owner/repo && gh repo fork owner/repo

# Issues
gh issue list --state open --label bug
gh issue create --title "Bug report" --body "Description"
gh issue view 123 && gh issue close 123

# Pull Requests
gh pr create --title "Feature X" --body "Description"
gh pr create --fill          # Auto-fill from commits
gh pr view 123 && gh pr merge 123 --squash  # Also: --merge, --rebase

# Releases
gh release create v1.2.3 --generate-notes [--draft]
gh release list / view / download v1.2.3

# Workflow runs
gh run list && gh run view 123456 && gh run watch
gh run rerun 123456 --failed

# API
gh api repos/owner/repo/issues [-f title="Bug" -f body="Details"]
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "not logged in" | `gh auth login -s workflow` |
| "token expired" | `gh auth refresh` |
| Wrong account | `gh auth switch` |
| "refusing to allow...workflow scope" | `gh auth refresh -s workflow` |
| Need token for script | `export GH_TOKEN=$(gh auth token)` |

## External Repo Submissions

Bots may auto-close non-conforming submissions. Check templates first.

### Discovering Templates

```bash
# Issue templates (list, then fetch specific template)
gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE/ --jq '.[].name' || true
gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE/bug-report.yml --jq '.content' | base64 -d || true

# CONTRIBUTING.md and PR templates
gh api repos/{owner}/{repo}/contents/CONTRIBUTING.md --jq '.content' | base64 -d || true
gh api repos/{owner}/{repo}/contents/.github/PULL_REQUEST_TEMPLATE.md --jq '.content' | base64 -d || true
```

### YAML Form Templates → Markdown

GitHub YAML issue forms (`.yml`) produce markdown with `### Label` headers matching each field's `label:` attribute. Replicate this structure:

```yaml
# Template defines:           # Your issue body:
- type: textarea              ### Describe the bug
  attributes:                 The app crashes on Save.
    label: Describe the bug
- type: input                 ### Version
  attributes:                 v2.4.1
    label: Version
```

**Rules:** Match `label:` exactly (case-sensitive). Required fields must be non-empty. `type: checkboxes` → `- [x]`/`- [ ]` lists. `type: dropdown` → selected option text.

### Auto-Close Bots

1. Read the bot's closing comment — it explains what's missing
2. Resubmit with correct format (don't edit closed issues)
3. Some bots use AI to verify compliance — partial matches may fail

### Pre-Submission Checklist

1. Repo in `~/.config/aidevops/repos.json`? Skip checks (it's ours)
2. `.github/ISSUE_TEMPLATE/` exists? Use matching template
3. `CONTRIBUTING.md` exists? Follow its guidelines (CLA, branch naming)
4. PRs: check for signed commits, branch targets, linked issue requirements

## See Also

- `lumen.md` — AI-powered visual diffs, commit messages, PR review
- `conflict-resolution.md` — Git conflict resolution
- `worktrunk.md` — Worktree management
