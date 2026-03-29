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

| Platform | CLI | Install | Auth |
|----------|-----|---------|------|
| GitHub | `gh` | `brew install gh` | `gh auth login` |
| GitLab | `glab` | `brew install glab` | `glab auth login` |
| Gitea | `tea` | `brew install tea` | `tea login add` |

**Branching**: `workflows/branch.md`

**Subagents**: `git/github-cli.md`, `git/gitlab-cli.md`, `git/gitea-cli.md`, `git/github-actions.md`, `git/authentication.md`, `git/git-security.md`, `git/opencode-github.md`, `git/opencode-gitlab.md`

<!-- AI-CONTEXT-END -->

## Common Operations

| Operation | GitHub (`gh`) | GitLab (`glab`) | Gitea (`tea`) |
|-----------|---------------|-----------------|---------------|
| Create repo | `gh repo create my-repo --public` | `glab repo create my-repo --public` | — |
| Clone | `gh repo clone owner/repo` | `glab repo clone owner/repo` | — |
| Fork | `gh repo fork owner/repo` | — | — |
| Create PR/MR | `gh pr create --fill` | `glab mr create --fill` | `tea pulls create` |
| List PRs/MRs | `gh pr list` | `glab mr list` | — |
| Merge | `gh pr merge 123 --squash` | `glab mr merge 123 --squash` | — |
| Create release | `gh release create v1.0.0 --generate-notes` | `glab release create v1.0.0 --notes "Notes"` | `tea releases create v1.0.0` |
| List releases | `gh release list` | `glab release list` | — |

## Authentication

CLI auth stores tokens in the system keyring (preferred). For scripts:

```bash
export GITHUB_TOKEN=$(gh auth token)
export GITLAB_TOKEN=$(glab auth token)
```

See `git/authentication.md` for detailed token setup.

## Multi-Platform Setup

For repositories mirrored across platforms:

```bash
git remote add github git@github.com:user/repo.git
git remote add gitlab git@gitlab.com:user/repo.git
git push github main
git push gitlab main

# Combined remote (push to all at once)
git remote add all git@github.com:user/repo.git
git remote set-url --add --push all git@github.com:user/repo.git
git remote set-url --add --push all git@gitlab.com:user/repo.git
git push all main
```

## OpenCode Integration

AI-powered issue/PR automation from GitHub or GitLab.

### GitHub

```bash
~/.aidevops/agents/scripts/opencode-github-setup-helper.sh check  # Check status
opencode github install                                            # Automated setup
```

Use `/oc` or `/opencode` in any issue/PR comment:
- `/oc explain this issue`
- `/oc fix this bug`
- `/opencode review this PR`

See `git/opencode-github.md` for full details.

### GitLab

Add OpenCode to `.gitlab-ci.yml` and use `@opencode` in comments:
- `@opencode explain this issue`
- `@opencode fix this`

See `git/opencode-gitlab.md` for full details.

## Related

- `workflows/branch.md` — Branching workflows
- `workflows/pr.md` — Pull requests
- `workflows/version-bump.md` — Version management
- `workflows/release.md` — Releases
- `git/github-actions.md` — CI/CD
- `git/git-security.md` — Security
- `git/opencode-github.md` — OpenCode GitHub
- `git/opencode-gitlab.md` — OpenCode GitLab
