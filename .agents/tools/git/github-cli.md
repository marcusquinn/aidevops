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
# Auth — always include workflow scope
gh auth login -s workflow && gh auth status
gh auth refresh -s workflow  # Add scope to existing token
gh auth switch               # Switch accounts
gh auth token                # Get token for scripts

# Repos / Issues / PRs / Releases / Runs
gh repo list / create / clone / view / fork
gh issue list / create / view / close
gh pr list / create / view / merge
gh release list / create / view / download
gh run list / view / watch / rerun
gh api repos/owner/repo      # Direct API access
```

**Required scope: `workflow`** — Without it, pushes modifying `.github/workflows/` fail with "refusing to allow...workflow scope". Fix: `gh auth refresh -s workflow`.

<!-- AI-CONTEXT-END -->

## Core Commands

```bash
# Repos
gh repo create my-repo --public --description "My project"
gh repo clone owner/repo && gh repo fork owner/repo

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

Bots auto-close non-conforming submissions — check templates before submitting.

### Fetch Templates

```bash
# Issue templates
gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE/ --jq '.[].name' || true
gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE/bug-report.yml --jq '.content' | base64 -d || true

# CONTRIBUTING.md and PR template
gh api repos/{owner}/{repo}/contents/CONTRIBUTING.md --jq '.content' | base64 -d || true
gh api repos/{owner}/{repo}/contents/.github/PULL_REQUEST_TEMPLATE.md --jq '.content' | base64 -d || true
```

### YAML Form Templates → Markdown

YAML issue forms (`.yml`) map each `label:` to a `### Label` header in the body. Match `label:` exactly (case-sensitive). Required fields must be non-empty. `type: checkboxes` → `- [x]`/`- [ ]`. `type: dropdown` → selected option text.

### Pre-Submission Checklist

1. Repo in `~/.config/aidevops/repos.json`? Skip checks (it's ours)
2. `.github/ISSUE_TEMPLATE/` exists? Use matching template
3. `CONTRIBUTING.md` exists? Follow its guidelines (CLA, branch naming)
4. PRs: check for signed commits, branch targets, linked issue requirements
5. If bot closes: read its comment for what's missing; resubmit (don't edit closed issues)

## See Also

- `lumen.md` — AI-powered visual diffs, commit messages, PR review
- `conflict-resolution.md` — Git conflict resolution
- `worktrunk.md` — Worktree management
