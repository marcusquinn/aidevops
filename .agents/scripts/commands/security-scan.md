---
description: Quick security scan for secrets and common vulnerabilities
agent: Build+
mode: subagent
---

Fast security check before commits. Target: $ARGUMENTS

## Process

Run each step, report findings with severity and location.

1. **Secretlint** — credential detection (API keys, private keys, hardcoded passwords for AWS, GCP, GitHub, OpenAI, etc.):

   ```bash
   ./.agents/scripts/secretlint-helper.sh scan
   ```

2. **Ferret** — AI CLI config security (prompt injection, jailbreaks):

   ```bash
   ./.agents/scripts/security-helper.sh ferret
   ```

3. **Quick code scan** — staged/diff analysis (command injection, SQL injection):

   ```bash
   ./.agents/scripts/security-helper.sh analyze staged
   ```

4. **MCP audit** — prompt injection in MCP tool descriptions:

   ```bash
   ./.agents/scripts/mcp-audit-helper.sh scan
   ```

5. **Secret hygiene & supply chain** — plaintext secrets (AWS, GCP, Azure, k8s, Docker, npm, PyPI, SSH), `.pth` IoCs, unpinned deps (`>=` in requirements.txt, `^` in package.json), `uvx`/`npx` auto-download risk in MCP configs:

   ```bash
   aidevops security scan
   # Or directly: ./.agents/scripts/secret-hygiene-helper.sh scan
   ```

For deeper analysis, use `/security-analysis` (full taint analysis, git history scanning, detailed remediation).

## CLI Reference

```bash
aidevops security              # ALL checks (posture + hygiene + supply chain)
aidevops security posture      # Interactive setup (gopass, gh, SSH, secretlint)
aidevops security status       # Combined posture + hygiene summary
aidevops security scan         # Secret hygiene & supply chain only
aidevops security scan-pth     # Python .pth file audit only
aidevops security scan-secrets # Plaintext secret locations only
aidevops security scan-deps    # Unpinned dependency check only
aidevops security check        # Per-repo security posture assessment
aidevops security dismiss <id> # Dismiss advisory after action
```
