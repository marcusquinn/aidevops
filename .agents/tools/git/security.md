---
description: Git security practices and secret scanning
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

# Git Security Practices

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Token storage**: `~/.config/aidevops/` (600 permissions)
- **Never commit**: API keys, tokens, passwords, secrets
- **Branch protection**: Enable for `main` branch
- **Signed commits**: Use GPG signing for verification
- **2FA**: Enable on all Git platforms

**Pre-commit check**:

```bash
git diff --cached | grep -iE "(api_key|token|password|secret)" && echo "WARNING: Possible secret!"
```

<!-- AI-CONTEXT-END -->

## Authentication Security

### Use CLI Authentication

```bash
# Stores tokens in system keyring (secure)
gh auth login
glab auth login
tea login add
```

Avoid environment variables when possible - CLI auth is more secure.

### Token Management

```bash
# Store tokens securely
mkdir -p ~/.config/aidevops
chmod 700 ~/.config/aidevops
echo "GITHUB_TOKEN=xxx" >> ~/.config/aidevops/mcp-env.sh
chmod 600 ~/.config/aidevops/mcp-env.sh
```

### Token Rotation

- Rotate tokens every 6-12 months
- Immediately rotate if exposed
- Use short-lived tokens for CI/CD

## Repository Security

### Branch Protection

Enable for `main` branch:

```bash
# Via GitHub CLI
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  -f required_status_checks='{"strict":true,"contexts":[]}' \
  -f enforce_admins=true \
  -f required_pull_request_reviews='{"required_approving_review_count":1}'
```

Or via web UI:
1. Settings → Branches → Add rule
2. Branch name pattern: `main`
3. Enable:
   - Require pull request reviews
   - Require status checks
   - Require signed commits (optional)

### Required Reviews

- Require at least 1 approval before merge
- Dismiss stale reviews on new commits
- Require review from code owners

### Status Checks

- Require CI to pass before merge
- Include security scanning
- Include linting/tests

## Commit Security

### Signed Commits

```bash
# Generate GPG key
gpg --full-generate-key

# Get key ID
gpg --list-secret-keys --keyid-format=long

# Configure git
git config --global user.signingkey YOUR_KEY_ID
git config --global commit.gpgsign true

# Sign commits
git commit -S -m "Signed commit"
```

### Pre-commit Hooks

Prevent accidental secret commits:

```bash
# .git/hooks/pre-commit
#!/bin/bash
if git diff --cached | grep -iE "(api_key|token|password|secret|private_key)" > /dev/null; then
    echo "ERROR: Possible secret detected in commit!"
    echo "Review your changes before committing."
    exit 1
fi
```

## Secret Detection

### Tools

- **secretlint**: `.agents/scripts/secretlint-helper.sh`
- **git-secrets**: AWS secret detection
- **trufflehog**: Historical secret scanning

### Scanning

```bash
# Scan for secrets
./.agents/scripts/secretlint-helper.sh scan

# Scan git history
trufflehog git file://. --only-verified
```

## Access Control

### Team Permissions

| Role | Permissions |
|------|-------------|
| Read | View code, issues |
| Triage | Manage issues, no code push |
| Write | Push to non-protected branches |
| Maintain | Push to protected, manage settings |
| Admin | Full access |

### Principle of Least Privilege

- Grant minimum necessary permissions
- Review access quarterly
- Remove inactive collaborators
- Use teams for group permissions

## Incident Response

### If Token Exposed

1. **Immediately revoke** the token
2. Generate new token
3. Update all systems using it
4. Audit for unauthorized access
5. Review how exposure happened

### If Secrets Committed

1. **Rotate the secret immediately**
2. Remove from git history:

   ```bash
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch path/to/secret" \
     --prune-empty --tag-name-filter cat -- --all
   git push origin --force --all
   ```

3. Force-push to all remotes
4. Notify affected parties

## Related

- **Token setup**: `git/authentication.md`
- **CLI tools**: `tools/git.md`
