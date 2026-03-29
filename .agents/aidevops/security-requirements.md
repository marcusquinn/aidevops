---
description: Critical security compliance requirements
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
---

# Security Requirements - CRITICAL COMPLIANCE

<!-- AI-CONTEXT-START -->

## Quick Reference

- **NEVER**: Hardcode API keys, commit credentials, include keys in commit messages
- **ALWAYS**: Environment variables, GitHub Secrets for CI/CD, template placeholders
- **Protected Files**: `configs/*-config.json`, `.env`, `*.key`, `*.pem`, `secrets/`
- **Templates OK**: `configs/service-config.json.txt` with `YOUR_API_TOKEN_HERE` placeholders
- **If Exposed**: Revoke immediately → Generate new → Update local + GitHub → Clean Git history
- **Rotation**: Every 90 days for Codacy, SonarCloud, GitHub tokens
- **Audits**: Monthly key review, quarterly access review, annual policy review

<!-- AI-CONTEXT-END -->

## API Key Management (MANDATORY)

**Never allowed:** hardcoding keys in source, committing credentials, storing secrets in Git-tracked configs, sharing keys in docs/comments, including keys in commit messages (CRITICAL VIOLATION), exposing credentials in Git history.

**Local development:**

```bash
export CODACY_API_TOKEN="your_token_here"
export SONAR_TOKEN="your_token_here"
export GITHUB_TOKEN="your_token_here"
echo 'export CODACY_API_TOKEN="your_token_here"' >> ~/.bashrc
```

**GitHub Actions:**

```yaml
env:
  CODACY_API_TOKEN: ${{ secrets.CODACY_API_TOKEN }}
  SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
```

**Config file templates:**

```json
{
  "api_token": "YOUR_API_TOKEN_HERE",
  "api_token": "${CODACY_API_TOKEN}"
}
```

## File Security

**.gitignore protected files:**

```text
configs/*-config.json
.env
.env.local
*.key
*.pem
secrets/
```

**Template pattern:** `configs/service-config.json.txt` (committed, placeholders) → `configs/service-config.json` (gitignored, actual values).

## Incident Response

**If API key is exposed** (all steps are IMMEDIATE):

1. Revoke the exposed key at provider
2. Generate new API key
3. Update local environment variables
4. Update GitHub Secrets
5. Remove key from Git history if committed
6. Log incident and remediation steps

**Git history cleanup:**

```bash
# Remove sensitive file from history
git filter-branch --force --index-filter \
  'git rm --cached --ignore-unmatch path/to/sensitive/file' \
  --prune-empty --tag-name-filter cat -- --all

# Fix commit message containing a key
git reset --hard COMMIT_HASH
git commit --amend -F secure-message.txt
git cherry-pick SUBSEQUENT_COMMITS
git push --force-with-lease origin main

# Force push to rewrite history
git push origin --force --all
```

## Pre-Commit Verification

```bash
# Scan for potential secrets
grep -r "api_token.*:" . --include="*.sh" --include="*.json"
grep -r "API_TOKEN.*=" . --include="*.sh" --include="*.yml"

# Verify .gitignore coverage
git status --ignored
```

## Provider Token Details

| Provider | Token source | Scope | Rotation |
|----------|-------------|-------|----------|
| Codacy | `app.codacy.com/account/api-tokens` | Repository analysis only | 90 days |
| SonarCloud | `sonarcloud.io/account/security` | Project analysis only | 90 days |
| GitHub | Personal Access Tokens (fine-grained preferred) | Minimal required scopes | Regular review |

## Compliance Checklist

- [ ] No API keys in source code
- [ ] All sensitive configs in .gitignore
- [ ] Environment variables configured locally
- [ ] GitHub Secrets configured for CI/CD
- [ ] Regular key rotation schedule established (90 days for Codacy, SonarCloud, GitHub)
- [ ] Incident response procedures documented
- [ ] Security audit schedule: monthly key review, quarterly access, annual policy
