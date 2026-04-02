---
description: Run comprehensive AI-powered security vulnerability analysis on codebase
agent: Build+
mode: subagent
---

Target: $ARGUMENTS

## Quick Reference

- **Helper**: `.agents/scripts/security-helper.sh`
- **Scopes**: `diff` (default), `staged`, `branch`, `full`, or specific path
- **Output**: `.security-analysis/` directory with reports

## Process

1. **Determine scope** from $ARGUMENTS:
   - Empty or `diff` → Analyze uncommitted changes
   - `staged` → Analyze staged changes only
   - `branch` → Analyze all commits on current branch vs main
   - `full` → Scan entire codebase
   - Path (e.g., `src/`) → Scan specific directory

2. **Run security analysis**:

   ```bash
   # Default: analyze git diff
   ./.agents/scripts/security-helper.sh analyze

   # Full codebase scan
   ./.agents/scripts/security-helper.sh analyze full

   # Specific scope
   ./.agents/scripts/security-helper.sh analyze $ARGUMENTS
   ```

3. **Review findings** by severity (critical > high > medium > low)

4. **For each finding**:
   - Verify it's a true positive (not false positive)
   - Trace data flow from source to sink (reconnaissance → investigation)
   - Propose remediation with code fix

5. **Generate report**:

   ```bash
   ./.agents/scripts/security-helper.sh report
   ```

6. **Provide output**:
   - Summary: total findings by severity
   - Critical/High findings: detailed with file:line, CWE, and remediation
   - Recommendations: prioritized action items
   - Report location: path to generated reports

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
