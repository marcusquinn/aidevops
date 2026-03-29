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

- **Token storage**: `~/.config/aidevops/credentials.sh` (600 perms) or gopass
- **Never commit**: API keys, tokens, passwords, secrets
- **Branch protection**: Required on `main` — PRs, status checks, signed commits
- **Secret scanning**: `secretlint-helper.sh scan` before every push
- **Incident**: Rotate first, remove from history second

<!-- AI-CONTEXT-END -->

## Authentication

Use CLI auth — stores tokens in system keyring, not env vars:

```bash
gh auth login -s workflow   # -s workflow for CI PR support
glab auth login
tea login add
```

Token storage: `~/.config/aidevops/credentials.sh` (600 perms). Rotate every 6–12 months; immediately if exposed. Use short-lived tokens for CI/CD.

## Branch Protection

```bash
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  -f required_status_checks='{"strict":true,"contexts":[]}' \
  -f enforce_admins=true \
  -f required_pull_request_reviews='{"required_approving_review_count":1}'
```

Require: PR reviews (dismiss stale), CI status checks, code owner review. Signed commits recommended.

## Commit Signing

```bash
gpg --full-generate-key
gpg --list-secret-keys --keyid-format=long   # get KEY_ID
git config --global user.signingkey KEY_ID
git config --global commit.gpgsign true
```

## Pre-commit Hook

```bash
# .git/hooks/pre-commit
#!/bin/bash
if git diff --cached | grep -iE "(api_key|token|password|secret|private_key)" > /dev/null; then
    echo "ERROR: Possible secret detected — review before committing."
    exit 1
fi
```

## Secret Detection

```bash
./.agents/scripts/secretlint-helper.sh scan   # current state
trufflehog git file://. --only-verified        # git history
```

Tools: `secretlint-helper.sh` (primary), `git-secrets` (AWS), `trufflehog` (history).

## Access Control

Principle of least privilege: grant minimum necessary, review quarterly, remove inactive collaborators. Use teams for group permissions.

| Role | Permissions |
|------|-------------|
| Read | View code, issues |
| Triage | Manage issues, no push |
| Write | Push to non-protected branches |
| Maintain | Push to protected, manage settings |
| Admin | Full access |

## Incident Response

**Token exposed:**
1. Revoke immediately
2. Generate replacement
3. Update all consumers
4. Audit for unauthorized access

**Secret committed:**
1. **Rotate the secret first** — assume it's compromised
2. Remove from history:

   ```bash
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch path/to/secret" \
     --prune-empty --tag-name-filter cat -- --all
   git push origin --force --all
   ```

3. Notify affected parties

## Related

- **Token setup**: `git/authentication.md`
- **CLI tools**: `tools/git.md`
- **Secret storage**: `tools/credentials/gopass.md`
