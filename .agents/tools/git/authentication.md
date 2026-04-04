---
description: Authentication setup for GitHub, GitLab, and Gitea
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Git Platform Authentication

<!-- AI-CONTEXT-START -->

## Quick Reference

| Platform | Token Location | Required Scopes |
|----------|---------------|-----------------|
| GitHub | Settings → Developer settings → Personal access tokens | `repo`, `workflow`, `admin:repo_hook`, `user` |
| GitLab | User Settings → Access Tokens | `api`, `read_repository`, `write_repository` |
| Gitea | Settings → Applications | Full access |

**Secure storage**: `~/.config/aidevops/` (600 permissions). Never store tokens in repository files.

<!-- AI-CONTEXT-END -->

## GitHub

1. Settings → Developer settings → Personal access tokens → **Generate new token (classic)**
2. Scopes: `repo`, `workflow` (required for CI PRs), `admin:repo_hook`, `user`
3. Store:

```bash
gh auth login -s workflow,admin:repo_hook,user  # recommended — grants all required scopes
# or
echo "GITHUB_TOKEN=ghp_xxxx" >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

4. Verify: `gh auth status`

## GitLab

1. User Settings → Access Tokens → create token
2. Scopes: `api`, `read_repository`, `write_repository`, `read_user`
3. Store:

```bash
glab auth login                                      # recommended
glab auth login --hostname gitlab.company.com        # self-hosted
# or
echo "GITLAB_TOKEN=glpat-xxxx" >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

4. Verify: `glab auth status`

## Gitea

1. Settings → Applications → Generate new access token
2. Store:

```bash
tea login add --name myserver --url https://git.example.com --token YOUR_TOKEN
# or
echo "GITEA_TOKEN=xxxx" >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

3. Verify: `tea login list`

## Token Security

- **Minimal scopes** — only request what you need
- **Rotate** every 6–12 months
- **600 permissions** on `~/.config/aidevops/credentials.sh`
- **Never commit** tokens to version control
- **Prefer CLI auth** (`gh auth login`) over env vars
- **Monitor** API access logs periodically

## Related

- **CLI usage**: `tools/git.md`
- **Security practices**: `git/git-security.md`
