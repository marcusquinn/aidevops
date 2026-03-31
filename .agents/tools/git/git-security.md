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

CLI auth stores tokens in system keyring (not env vars):

```bash
gh auth login -s workflow   # -s workflow for CI PR support
```

Token storage: `~/.config/aidevops/credentials.sh` (600 perms). Rotate every 6-12 months; immediately if exposed. Short-lived tokens for CI/CD. See `git/authentication.md` for full setup.

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

## Secret Detection

Primary: `secretlint-helper.sh scan`. History: `trufflehog git file://. --only-verified`. Also: `git-secrets` (AWS patterns).

Pre-commit hook (supplementary — secretlint is primary):

```bash
# .git/hooks/pre-commit
#!/bin/bash
if git diff --cached | grep -iE "(api_key|token|password|secret|private_key)" > /dev/null; then
    echo "ERROR: Possible secret detected — review before committing."
    exit 1
fi
```

## Incident Response

**Token exposed:** Revoke immediately → generate replacement → update consumers → audit for unauthorized access.

**Secret committed:**

1. **Rotate the secret first** — assume compromised
2. Remove from history:

   ```bash
   # Preferred: git-filter-repo (pip install git-filter-repo)
   git filter-repo --invert-paths --path path/to/secret
   git push origin --force --all
   ```

3. Notify affected parties

## Related

- **Token setup**: `git/authentication.md`
- **CLI tools**: `tools/git.md`
- **Secret storage**: `tools/credentials/gopass.md`
