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

| Attack | Mitigations | Residual risk |
|--------|-------------|---------------|
| **Prompt injection** | `ai-approved` label; pattern detection; system prompt forbids unsafe actions | Medium — human PR review |
| **Unauthorized execution** | OWNER/MEMBER/COLLABORATOR only; all attempts logged | Low — audit logs, PR review |
| **Credential exfiltration** | System prompt forbids credential files; pattern detection blocks secrets; no external network | Low — GitHub Secrets, rotation policy |
| **Workflow tampering** | System prompt forbids workflow edits; `actions:` permission not granted | Low — PR review, CI checks |
| **Resource exhaustion** | Concurrency limit: one at a time; 15-min timeout; collaborators only | — |

## Security Configuration

### Labels

```bash
gh label create "ai-approved" --color "0E8A16" --description "Issue approved for AI agent processing"
gh label create "security-review" --color "D93F0B" --description "Requires security review - suspicious AI request"
```

### Secrets

Only `ANTHROPIC_API_KEY` required (rotate every 90 days). Do NOT add PATs with elevated permissions, deployment credentials, or other API keys.

### Branch Protection

Require on `main`/`master`: PR reviews, status checks, branches up to date, no bypass. Ensures AI-created PRs always need human review.

## Suspicious Pattern Detection

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

## Audit Logging

Every invocation logs: timestamp, event type, allowed/denied, user, association, issue number, command, run URL.

View: Repository > Actions > OpenCode AI Agent > Select run > audit-log job.

## Usage Examples

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

External contributors (CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, NONE) cannot trigger the agent.

**Maintainers — approving issues**: Review content for safety, check raw markdown for hidden content, add `ai-approved` label. For `security-review` alerts: check Actions log, review triggering comment, remove label or take action.

## Monitoring

```bash
gh run list --workflow=opencode-agent.yml --limit=20
gh run view <run-id> --log
```

Set up failure notifications: Repository > Settings > Actions > General > Email notifications.

Periodic review: `security-review` issues, audit logs, branch protection, API key rotation (90 days), AI-created PRs.

## Incident Response

| Scenario | Steps |
|----------|-------|
| **Suspicious activity** | 1. Disable: `gh workflow disable opencode-agent.yml` 2. Investigate: `gh run list --workflow=opencode-agent.yml --json conclusion,createdAt,headBranch` 3. Contain: `git revert <commit-sha>` 4. Rotate API key 5. Document and update patterns |
| **API key compromised** | 1. Rotate immediately in Anthropic dashboard 2. Update GitHub Secret 3. Review recent API usage 4. Check if key was exposed in logs/commits |

## Related

- `tools/git/opencode-github.md` — Setup guide (includes permission model, token options)
- `tools/git/github-cli.md` — GitHub CLI reference
- `workflows/git-workflow.md` — Git workflow standards
