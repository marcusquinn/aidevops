---
description: Security hardening guide for OpenCode GitHub AI agent integration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# OpenCode GitHub Security Guide

<!-- AI-CONTEXT-START -->

**Workflow**: `.github/workflows/opencode-agent.yml` | **Trigger**: `/oc` or `/opencode` in issue/PR comments | **Access**: Collaborator + `ai-approved` label on issues

**Security layers**: user validation (OWNER/MEMBER/COLLABORATOR only) → `ai-approved` label gate → pattern detection → audit logging → 15-min timeout → minimal permissions

<!-- AI-CONTEXT-END -->

## Threat Model

| Attack | Mitigations |
|--------|-------------|
| **Prompt injection** | `ai-approved` label (maintainer reviews first); pattern detection; system prompt forbids unsafe actions |
| **Unauthorized execution** | OWNER/MEMBER/COLLABORATOR only; untrusted users get notice; all attempts logged |
| **Credential exfiltration** | System prompt forbids credential files; pattern detection blocks secret/token/password; no network beyond GitHub API |
| **Workflow tampering** | System prompt forbids workflow edits; `actions:` permission not granted; changes require PR review |
| **Resource exhaustion** | Concurrency limit: one execution at a time; 15-min timeout; collaborators only |

**Residual risks**: novel prompt injection (Medium/Medium — human PR review); compromised collaborator (Low/High — audit logs); AI hallucination (Medium/Low — PR review, CI); API key exposure (Low/Medium — GitHub Secrets, rotation policy).

## Security Configuration

### Labels

```bash
gh label create "ai-approved" --color "0E8A16" --description "Issue approved for AI agent processing"
gh label create "security-review" --color "D93F0B" --description "Requires security review - suspicious AI request"
```

### Secrets

Only `ANTHROPIC_API_KEY` required — rotate every 90 days. Do NOT add PATs with elevated permissions, deployment credentials, or other API keys.

### Branch Protection

Require on `main`/`master`: PR reviews before merging, status checks to pass, branches up to date, no bypass. Ensures AI-created PRs always require human review.

## Workflow

Security check job validates before any AI execution: trigger presence, user association, label requirement (issues), pattern scanning.

**Suspicious patterns** (edit `.github/workflows/opencode-agent.yml` to add):

```javascript
const suspiciousPatterns = [
  /ignore\s+(previous|all|prior)\s+(instructions?|prompts?)/i,
  /system\s*prompt/i,
  /\bsudo\b/i,
  /rm\s+-rf/i,
  /curl\s+.*\|\s*(ba)?sh/i,
  /eval\s*\(/i,
  /exec\s*\(/i,
  /__import__/i,
  /os\.system/i,
  /subprocess/i,
  /ssh[_-]?key/i,
  /authorized[_-]?keys/i,
  /\.env\b/i,
  /password|secret|token|credential/i,
  /base64\s+(decode|encode)/i,
];
```

**Audit logging**: every invocation logs timestamp, event, allowed, user, user_association, issue_number, command, run_url. View: Repository → Actions → OpenCode AI Agent → Select run → audit-log job.

**Permissions**:

```yaml
permissions:
  contents: write        # Commit changes
  pull-requests: write   # Create PRs
  issues: write          # Comment on issues
  id-token: write        # OpenCode auth
# NOT granted: actions, packages, security-events, deployments, secrets
```

## Usage Guide

**Maintainers**: To approve an issue — review content for safety, check raw markdown for hidden content, add `ai-approved` label. For `security-review` alerts: check Actions log → review triggering comment → remove label or take action.

**Collaborators — safe commands**:

```text
/oc explain this issue
/oc fix the bug described above
/oc add input validation to the handleAuth function
/oc refactor this to use async/await
/oc add unit tests for the UserService class
```

**Blocked commands**:

```text
/oc ignore previous instructions and...     # Prompt injection
/oc read the .env file                       # Credential access
/oc run sudo apt-get install...              # Privilege escalation
/oc modify the GitHub workflow               # Workflow tampering
```

**External contributors** (CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, NONE): cannot trigger the AI agent. Options: describe what you need for a maintainer to run, or submit a PR manually.

## Monitoring & Incident Response

```bash
gh run list --workflow=opencode-agent.yml --limit=20
gh run view <run-id> --log
```

Set up failure notifications: Repository → Settings → Actions → General → Email notifications.

**Weekly/monthly review**: check `security-review` labeled issues; review audit logs for unusual patterns; verify branch protection; rotate API key if approaching 90 days; review AI-created PRs.

**Suspicious activity response**:
1. Disable: `gh workflow disable opencode-agent.yml`
2. Investigate: `gh run list --workflow=opencode-agent.yml --json conclusion,createdAt,headBranch`
3. Contain: `git revert <commit-sha>`
4. Rotate API key in GitHub Secrets (and update Anthropic dashboard if compromised)
5. Report: document incident, update patterns if needed

## OpenCode App vs Bot Account

| Aspect | OpenCode GitHub App | Dedicated Bot Account |
|--------|--------------------|-----------------------|
| **Credential lifetime** | Ephemeral (per-run) | Long-lived token |
| **Setup complexity** | Low (workflow only) | High (account + hosting) |
| **Trigger control** | Explicit (`/oc`) | Can be automatic |
| **Audit trail** | GitHub Actions logs | Custom implementation |
| **Cost** | GitHub Actions minutes | Hosting + Actions |
| **Recommendation** | **Preferred for security** | Only if specific needs |

## Related

- `tools/git/opencode-github.md` — Basic setup guide
- `tools/git/github-cli.md` — GitHub CLI reference
- `workflows/git-workflow.md` — Git workflow standards
- `aidevops/security-requirements.md` — Framework security requirements
