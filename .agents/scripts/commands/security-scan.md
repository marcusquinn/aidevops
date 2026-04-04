---
description: Quick security scan for secrets and common vulnerabilities
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Fast security check before commits. Target: $ARGUMENTS

Run every check below and report findings with severity and location.

## Process

1. **Secretlint** — credential detection (API keys, private keys, hardcoded passwords for AWS, GCP, GitHub, OpenAI, etc.): `./.agents/scripts/secretlint-helper.sh scan`
2. **Ferret** — AI CLI config security (prompt injection, jailbreaks): `./.agents/scripts/security-helper.sh ferret`
3. **Quick code scan** — staged/diff analysis (command injection, SQL injection): `./.agents/scripts/security-helper.sh analyze staged`
4. **MCP audit** — prompt injection in MCP tool descriptions: `./.agents/scripts/mcp-audit-helper.sh scan`
5. **Secret hygiene + supply chain** — plaintext secrets (AWS, GCP, Azure, k8s, Docker, npm, PyPI, SSH), `.pth` IoCs, unpinned deps (`>=` in requirements.txt, `^` in package.json), and `uvx`/`npx` auto-download risk in MCP configs: `aidevops security scan` or `./.agents/scripts/secret-hygiene-helper.sh scan`

For deeper analysis, use `/security-analysis` for taint analysis, git history scanning, and detailed remediation.

## CLI reference

- `aidevops security` — all checks: posture, hygiene, supply chain
- `aidevops security posture` — interactive setup: gopass, gh, SSH, secretlint
- `aidevops security status` — combined posture + hygiene summary
- `aidevops security scan` — secret hygiene + supply chain only
- `aidevops security scan-pth` — Python `.pth` audit only
- `aidevops security scan-secrets` — plaintext secret locations only
- `aidevops security scan-deps` — unpinned dependency check only
- `aidevops security check` — per-repo security posture assessment
- `aidevops security dismiss <id>` — dismiss advisory after action
