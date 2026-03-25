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

5. **Secret hygiene & supply chain scan** for plaintext credentials and IoCs:

   ```bash
   # Scan for plaintext secrets, .pth supply chain IoCs, unpinned deps
   aidevops security scan
   # Or directly:
   secret-hygiene-helper.sh scan
   ```

6. **Report findings** with severity and location

## What It Checks

| Check | Tool | Description |
|-------|------|-------------|
| API Keys | Secretlint | AWS, GCP, GitHub, OpenAI, etc. |
| Private Keys | Secretlint | RSA, SSH, PGP keys |
| Passwords | Secretlint | Hardcoded credentials |
| AI Configs | Ferret | Prompt injection, jailbreaks |
| MCP Descriptions | MCP Audit | Injection in MCP tool descriptions |
| Obvious Vulns | Security Helper | Command injection, SQL injection |
| Plaintext Secrets | Secret Hygiene | AWS, GCP, Azure, k8s, Docker, npm, PyPI, SSH |
| Supply Chain IoCs | Secret Hygiene | Python .pth files, compromised package versions |
| Unpinned Deps | Secret Hygiene | >= in requirements.txt, ^ in package.json |
| MCP Auto-Download | Secret Hygiene | uvx/npx in MCP configs (transitive dep risk) |

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

## Related CLI Commands

```bash
aidevops security              # Run ALL checks (posture + hygiene + supply chain)
aidevops security posture      # Interactive security posture setup (gopass, gh, SSH)
aidevops security status       # Combined posture + hygiene summary
aidevops security scan         # Secret hygiene & supply chain scan only
aidevops security scan-pth     # Python .pth file audit only
aidevops security scan-secrets # Plaintext secret locations only
aidevops security scan-deps    # Unpinned dependency check only
aidevops security check        # Per-repo security posture assessment
aidevops security dismiss <id> # Dismiss a security advisory after action
```
