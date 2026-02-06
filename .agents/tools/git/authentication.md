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

# Git Platform Authentication

<!-- AI-CONTEXT-START -->

## Quick Reference

| Platform | Token Location | Required Scopes |
|----------|---------------|-----------------|
| GitHub | Settings → Developer settings → Personal access tokens | `repo`, `admin:repo_hook`, `user` |
| GitLab | User Settings → Access Tokens | `api`, `read_repository`, `write_repository` |
| Gitea | Settings → Applications | Full access |

**Secure storage**: `~/.config/aidevops/` (600 permissions)
**Never**: Store tokens in repository files

<!-- AI-CONTEXT-END -->

## GitHub Personal Access Token

### Create Token

1. Go to **Settings** → **Developer settings** → **Personal access tokens**
2. Click **Generate new token (classic)**
3. Select scopes:
   - `repo` - Full control of private repositories
   - `admin:repo_hook` - Read and write repository hooks
   - `user` - Read user profile data
4. Generate and copy token

### Store Securely

```bash
# Using CLI (recommended)
gh auth login

# Or store for scripts
echo "GITHUB_TOKEN=ghp_xxxx" >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

### Verify

```bash
gh auth status
# or
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user
```

## GitLab Personal Access Token

### Create Token

1. Go to **User Settings** → **Access Tokens**
2. Create personal access token with scopes:
   - `api` - Access the authenticated user's API
   - `read_repository` - Read repository
   - `write_repository` - Write repository
   - `read_user` - Read user info
3. Copy token (shown only once)

### Store Securely

```bash
# Using CLI (recommended)
glab auth login

# For self-hosted
glab auth login --hostname gitlab.company.com

# Or store for scripts
echo "GITLAB_TOKEN=glpat-xxxx" >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

### Verify

```bash
glab auth status
```

## Gitea Access Token

### Create Token

1. Go to **Settings** → **Applications**
2. Generate new access token
3. Copy token (shown only once)

### Store Securely

```bash
# Using CLI
tea login add --name myserver --url https://git.example.com --token YOUR_TOKEN

# Or store for scripts
echo "GITEA_TOKEN=xxxx" >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

### Verify

```bash
tea login list
```

## Token Security Best Practices

1. **Minimal scopes** - Only request permissions you need
2. **Regular rotation** - Rotate tokens every 6-12 months
3. **Secure storage** - Use `~/.config/aidevops/` with 600 permissions
4. **Never in repos** - Never commit tokens to version control
5. **Use CLI auth** - Prefer `gh auth login` over env vars when possible
6. **Monitor usage** - Review API access logs periodically

## Related

- **CLI usage**: `tools/git.md`
- **Security practices**: `git/security.md`
