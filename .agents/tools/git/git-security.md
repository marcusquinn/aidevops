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

- **Store secrets**: `~/.config/aidevops/credentials.sh` (600 perms) or gopass
- **Never commit**: API keys, tokens, passwords, private keys, other secrets
- **Protect `main`**: PRs, required status checks, stale-review dismissal, admin enforcement
- **Scan before push**: `secretlint-helper.sh scan`; use `trufflehog` for history
- **Incident order**: rotate first, remove from history second

<!-- AI-CONTEXT-END -->

## Preventive Controls

Use CLI auth — keeps tokens in the system keyring, not repo files:

```bash
gh auth login -s workflow   # -s workflow for CI PR support
glab auth login
tea login add
```

Fallback: `~/.config/aidevops/credentials.sh` (600 perms). Rotate every 6-12 months or on exposure. Prefer short-lived CI/CD credentials. See `git/authentication.md`.

### Branch Protection

```bash
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  -f required_status_checks='{"strict":true,"contexts":[]}' \
  -f enforce_admins=true \
  -f required_pull_request_reviews='{"required_approving_review_count":1}'
```

Require PR reviews, dismiss stale approvals, enforce admins, require CI checks, CODEOWNERS where available. Signed commits recommended.

### Commit Signing

```bash
gpg --full-generate-key
gpg --list-secret-keys --keyid-format=long   # get KEY_ID
git config --global user.signingkey KEY_ID
git config --global commit.gpgsign true
```

### Secret Detection

Primary: `secretlint-helper.sh scan`. History: `trufflehog git file://. --only-verified`. `git-secrets` useful for AWS-focused checks.

Pre-commit hook (supplementary — secretlint is primary):

```bash
# .git/hooks/pre-commit
#!/bin/bash
if git diff --cached | grep -iE "(api_key|token|password|secret|private_key)" > /dev/null; then
    echo "ERROR: Possible secret detected — review before committing."
    exit 1
fi
```

## Access Control

Least privilege. Quarterly access review. Remove inactive collaborators. Prefer teams over direct grants.

| Role | Permissions |
|------|-------------|
| Read | View code/issues |
| Triage | Manage issues, no push |
| Write | Push to non-protected branches |
| Maintain | Settings + protected-branch workflows |
| Admin | Full access |

## Incident Response

**Token exposed:** revoke → replace → update consumers → audit for unauthorized use.

**Secret committed:**

1. **Rotate first** — assume compromise.
2. Remove from history (preferred: `git-filter-repo`):

   ```bash
   git filter-repo --invert-paths --path path/to/secret
   git push origin --force --all
   ```

   Fallback (`git filter-branch`, legacy):

   ```bash
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch path/to/secret" \
     --prune-empty --tag-name-filter cat -- --all
   git push origin --force --all
   ```

3. Notify affected parties.

## Related

- **Token setup**: `git/authentication.md`
- **CLI tools**: `tools/git.md`
- **Secret storage**: `tools/credentials/gopass.md`
