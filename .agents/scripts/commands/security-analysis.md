---
description: Run comprehensive AI-powered security vulnerability analysis on codebase
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Target: $ARGUMENTS

## Quick Reference

- **Helper**: `.agents/scripts/security-helper.sh`
- **Scopes**: `diff` (default), `staged`, `branch`, `full`, or specific path
- **Output**: `.security-analysis/` directory with reports

## Process

1. **Determine scope** from $ARGUMENTS: empty/`diff` → uncommitted changes; `staged` → staged only; `branch` → current branch vs main; `full` → entire codebase; path → specific directory.

2. **Run analysis**: `./.agents/scripts/security-helper.sh analyze [$ARGUMENTS]`

3. **Review findings** by severity (critical > high > medium > low). For each: verify true positive, trace data flow source→sink, propose remediation with code fix.

4. **Generate report**: `./.agents/scripts/security-helper.sh report`

5. **Output**: summary by severity; critical/high with file:line, CWE, remediation; prioritized recommendations; report path.

## Vulnerability Categories

| Category | Examples |
|----------|----------|
| Secrets | Hardcoded API keys, passwords, private keys |
| Injection | XSS, SQLi, command injection, SSRF |
| Crypto | Weak algorithms, insufficient key length |
| Auth | Bypass, weak sessions, insecure password reset |
| Data | PII violations, insecure deserialization |
| LLM Safety | Prompt injection, improper output handling |

## Related Commands

- `/security-scan` - Quick security scan (secrets + deps only)
- `/security-deps` - Dependency vulnerability scan
- `/security-history` - Scan git history for vulnerabilities

## Full Documentation

Read `tools/code-review/security-analysis.md` for complete reference.
