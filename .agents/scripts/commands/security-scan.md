---
description: Quick security scan for secrets and common vulnerabilities
agent: Build+
mode: subagent
---

Run a quick security scan focused on secrets detection and common vulnerabilities.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Fast security check before commits
- **Focus**: Secrets, credentials, obvious vulnerabilities
- **Use case**: Pre-commit hook, quick validation

## Process

1. **Run secretlint** for credential detection:

   ```bash
   # Check for exposed secrets
   ./.agents/scripts/secretlint-helper.sh scan
   ```

2. **Run Ferret** for AI CLI config security:

   ```bash
   # Scan AI assistant configurations
   ./.agents/scripts/security-helper.sh ferret
   ```

3. **Quick code scan** for obvious issues:

   ```bash
   # Fast analysis on staged/diff
   ./.agents/scripts/security-helper.sh analyze staged
   ```

4. **MCP tool description audit** for prompt injection in MCP servers:

   ```bash
   # Scan all configured MCP tool descriptions
   ./.agents/scripts/mcp-audit-helper.sh scan
   ```

5. **Report findings** with severity and location

## What It Checks

| Check | Tool | Description |
|-------|------|-------------|
| API Keys | Secretlint | AWS, GCP, GitHub, OpenAI, etc. |
| Private Keys | Secretlint | RSA, SSH, PGP keys |
| Passwords | Secretlint | Hardcoded credentials |
| AI Configs | Ferret | Prompt injection, jailbreaks |
| MCP Descriptions | MCP Audit | Injection in MCP tool descriptions |
| Obvious Vulns | Security Helper | Command injection, SQL injection |

## Output

Quick summary:

```text
Security Scan Results
=====================
Secrets: 0 found
AI Configs: 2 warnings (low severity)
Code Issues: 1 medium severity

Details:
- [MEDIUM] src/api/handler.ts:45 - Potential command injection
```

## When to Use

- Before committing code
- Quick validation during development
- CI/CD pre-merge check

## For Deeper Analysis

Use `/security-analysis` for comprehensive scanning with:
- Full taint analysis
- Git history scanning
- Detailed remediation guidance
