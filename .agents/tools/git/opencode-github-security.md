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

## Quick Reference

- **Workflow**: `.github/workflows/opencode-agent.yml`
- **Trigger**: `/oc` or `/opencode` in issue/PR comments
- **Requirements**: Collaborator access + `ai-approved` label on issues

**Security Layers**:

| Layer | Protection |
|-------|------------|
| User validation | OWNER/MEMBER/COLLABORATOR only |
| Label gate | `ai-approved` required on issues |
| Pattern detection | Blocks prompt injection attempts |
| Audit logging | All invocations logged |
| Timeout | 15 minute max execution |
| Permissions | Minimal required only |

<!-- AI-CONTEXT-END -->

## Threat Model

| Attack | Mitigations |
|--------|-------------|
| **Prompt injection** (hidden instructions in issues) | `ai-approved` label (maintainer reviews first); pattern detection; system prompt forbids unsafe actions |
| **Unauthorized execution** (untrusted user comments `/oc`) | OWNER/MEMBER/COLLABORATOR only; untrusted users get notice; all attempts logged |
| **Credential exfiltration** (`/oc read .env`) | System prompt forbids credential files; pattern detection blocks secret/token/password mentions; no network beyond GitHub API |
| **Workflow tampering** (`/oc modify the workflow`) | System prompt forbids workflow edits; `actions:` permission not granted; changes require PR review |
| **Resource exhaustion** (spam `/oc`) | Concurrency limit: one execution at a time; 15-min timeout; collaborators only |

### Residual Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Novel prompt injection | Medium | Medium | Human PR review required |
| Compromised collaborator | Low | High | Audit logs, PR review |
| AI hallucination/mistakes | Medium | Low | PR review, CI checks |
| API key exposure | Low | Medium | GitHub Secrets, rotation policy |

## Security Configuration

### Required Labels

```bash
gh label create "ai-approved" --color "0E8A16" --description "Issue approved for AI agent processing"
gh label create "security-review" --color "D93F0B" --description "Requires security review - suspicious AI request"
```

| Label | Color | Purpose |
|-------|-------|---------|
| `ai-approved` | `#0E8A16` | Issue vetted for AI processing |
| `security-review` | `#D93F0B` | Auto-added when suspicious patterns detected |

### Secrets Configuration

Only one secret required: `ANTHROPIC_API_KEY` (rotate every 90 days).

**Do NOT add**: Personal Access Tokens with elevated permissions, deployment credentials, or other API keys.

### Branch Protection

Require on `main`/`master`: PR reviews before merging, status checks to pass, branches up to date, no bypass. This ensures AI-created PRs always require human review.

## Workflow Deep Dive

### Security Check Job

Validates before any AI execution. Checks: trigger presence, user association (must be trusted), label requirement (issues), pattern scanning.

### Suspicious Pattern Detection

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

To add patterns: edit `.github/workflows/opencode-agent.yml`.

### Audit Logging

Every invocation logs:

```json
{
  "timestamp": "2025-01-09T12:00:00Z",
  "event": "opencode-agent-trigger",
  "allowed": true,
  "user": "username",
  "user_association": "MEMBER",
  "issue_number": 123,
  "command": "/oc fix the bug in auth.ts",
  "run_url": "https://github.com/.../actions/runs/..."
}
```

View: Repository → Actions → OpenCode AI Agent → Select run → audit-log job

### Permission Model

```yaml
permissions:
  contents: write        # Commit changes
  pull-requests: write   # Create PRs
  issues: write          # Comment on issues
  id-token: write        # OpenCode auth
# NOT granted: actions, packages, security-events, deployments, secrets
```

## Usage Guide

### For Maintainers

**Approving an issue**: Review content for safety, check raw markdown for hidden content, add `ai-approved` label.

**Responding to `security-review` alerts**: Check Actions log for what was blocked → review triggering comment → determine false positive or threat → remove label or take action.

### For Collaborators

**Safe commands**:

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

### For External Contributors

External contributors (CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, NONE) cannot trigger the AI agent. Options: describe what you need and a maintainer can run it, or submit a PR manually.

## Monitoring & Alerts

```bash
# List recent AI agent runs
gh run list --workflow=opencode-agent.yml --limit=20

# View specific run logs
gh run view <run-id> --log
```

Set up failure notifications: Repository → Settings → Actions → General → Email notifications.

**Weekly/monthly review checklist**:
- [ ] Check for `security-review` labeled issues
- [ ] Review audit logs for unusual patterns
- [ ] Verify branch protection still enabled
- [ ] Rotate API key if approaching 90 days
- [ ] Review any PRs created by AI agent

## Incident Response

### Suspicious Activity

1. **Disable**: `gh workflow disable opencode-agent.yml`
2. **Investigate**: `gh run list --workflow=opencode-agent.yml --json conclusion,createdAt,headBranch`
3. **Contain**: `git revert <commit-sha>`
4. **Rotate**: Change API key in GitHub Secrets
5. **Report**: Document incident and update patterns if needed

### API Key Compromised

1. Rotate immediately in Anthropic dashboard
2. Update GitHub Secret
3. Review recent API usage for anomalies
4. Check if key was exposed in logs/commits

## OpenCode App vs Bot Account

| Aspect | OpenCode GitHub App | Dedicated Bot Account |
|--------|--------------------|-----------------------|
| **Credential lifetime** | Ephemeral (per-run) | Long-lived token |
| **Setup complexity** | Low (workflow only) | High (account + hosting) |
| **Trigger control** | Explicit (`/oc`) | Can be automatic |
| **Audit trail** | GitHub Actions logs | Custom implementation |
| **Cost** | GitHub Actions minutes | Hosting + Actions |
| **Recommendation** | **Preferred for security** | Only if specific needs |

## Related Documentation

- `tools/git/opencode-github.md` - Basic setup guide
- `tools/git/github-cli.md` - GitHub CLI reference
- `workflows/git-workflow.md` - Git workflow standards
- `aidevops/security-requirements.md` - Framework security requirements
