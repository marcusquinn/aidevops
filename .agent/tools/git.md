---
description: Git platform tools for GitHub, GitLab, and Gitea
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Git Tools

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Platforms**: GitHub, GitLab, Gitea
- **CLIs**: `gh` (GitHub), `glab` (GitLab), `tea` (Gitea)
- **Branching**: See `workflows/branch.md`

| Platform | CLI | Install | Auth |
|----------|-----|---------|------|
| GitHub | `gh` | `brew install gh` | `gh auth login` |
| GitLab | `glab` | `brew install glab` | `glab auth login` |
| Gitea | `tea` | `brew install tea` | `tea login add` |

**Subagents**:
- `git/github-cli.md` - GitHub CLI details
- `git/gitlab-cli.md` - GitLab CLI details
- `git/gitea-cli.md` - Gitea CLI details
- `git/github-actions.md` - CI/CD workflows
- `git/authentication.md` - Token setup
- `git/security.md` - Security practices

<!-- AI-CONTEXT-END -->

## Overview

Use official CLI tools for each Git platform. They handle authentication securely via system keyring and are actively maintained.

## Platform CLIs

### GitHub (`gh`)

The official GitHub CLI. See `git/github-cli.md` for details.

```bash
brew install gh
gh auth login
gh repo list
gh pr create
gh release create v1.0.0 --generate-notes
```

### GitLab (`glab`)

The official GitLab CLI. See `git/gitlab-cli.md` for details.

```bash
brew install glab
glab auth login
glab repo list
glab mr create
glab release create v1.0.0
```

### Gitea (`tea`)

The official Gitea CLI. See `git/gitea-cli.md` for details.

```bash
brew install tea
tea login add
tea repos list
tea pulls create
tea releases create v1.0.0
```

## Multi-Platform Setup

For repositories mirrored across platforms:

```bash
# Add multiple remotes
git remote add github git@github.com:user/repo.git
git remote add gitlab git@gitlab.com:user/repo.git

# Push to specific remote
git push github main
git push gitlab main

# Or create combined remote
git remote add all git@github.com:user/repo.git
git remote set-url --add --push all git@github.com:user/repo.git
git remote set-url --add --push all git@gitlab.com:user/repo.git
git push all main
```

## Authentication

**Recommended**: Use CLI authentication (stores in keyring)

```bash
gh auth login    # GitHub
glab auth login  # GitLab
tea login add    # Gitea
```

**For scripts** that need tokens:

```bash
export GITHUB_TOKEN=$(gh auth token)
export GITLAB_TOKEN=$(glab auth token)
```

See `git/authentication.md` for detailed token setup.

## Common Operations

### Repository Management

```bash
# Create
gh repo create my-repo --public
glab repo create my-repo --public

# Clone
gh repo clone owner/repo
glab repo clone owner/repo

# Fork
gh repo fork owner/repo
```

### Pull/Merge Requests

```bash
# Create PR/MR
gh pr create --fill
glab mr create --fill

# List
gh pr list
glab mr list

# Merge
gh pr merge 123 --squash
glab mr merge 123 --squash
```

### Releases

```bash
# Create with auto-generated notes
gh release create v1.0.0 --generate-notes
glab release create v1.0.0 --notes "Release notes"

# List
gh release list
glab release list
```

## Related

- **Branching workflows**: `workflows/branch.md`
- **Pull requests**: `workflows/pull-request.md`
- **Version management**: `workflows/version-bump.md`
- **Releases**: `workflows/release.md`
- **CI/CD**: `git/github-actions.md`
- **Security**: `git/security.md`
