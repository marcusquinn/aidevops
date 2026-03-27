---
description: AI-powered security vulnerability analysis for code changes, full codebase, and git history
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
mcp:
  - osv-scanner
  - gemini-cli-security
---

# Security Analysis - AI-Powered Vulnerability Detection

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `.agents/scripts/security-helper.sh`
- **Commands**: `analyze [scope]` | `scan-deps` | `history [commits]` | `skill-scan` | `vt-scan` | `ferret` | `report`
- **Scopes**: `diff` (default), `staged`, `branch`, `full`
- **Output**: `.security-analysis/` directory with reports
- **Severity**: critical > high > medium > low > info
- **Benchmarks**: 90% precision, 93% recall (OpenSSF CVE Benchmark)
- **Integrations**: OSV-Scanner (deps), Secretlint (secrets), Ferret (AI configs), VirusTotal (file/URL/domain), Shannon (pentesting), Snyk (optional)
- **MCP**: `gemini-cli-security` tools: find_line_numbers, get_audit_scope, run_poc

**Vulnerability Categories**:

| Category | Examples |
|----------|----------|
| Secrets | Hardcoded API keys, passwords, private keys, connection strings |
| Injection | XSS, SQLi, command injection, SSRF, SSTI |
| Crypto | Weak algorithms (DES, RC4, ECB), insufficient key length |
| Auth | Bypass, weak session tokens, insecure password reset |
| Data | PII violations, insecure deserialization, sensitive logging |
| LLM Safety | Prompt injection, improper output handling, insecure tool use |
| AI Config | Jailbreaks, backdoors, exfiltration in AI CLI configs (via Ferret) |

<!-- AI-CONTEXT-END -->

## Commands

```bash
./.agents/scripts/security-helper.sh analyze [diff|staged|branch|full]
./.agents/scripts/security-helper.sh history 50                          # or abc123..def456, --since=, --author=
./.agents/scripts/security-helper.sh scan-deps [path]
./.agents/scripts/security-helper.sh skill-scan                          # Cisco + VirusTotal advisory
./.agents/scripts/security-helper.sh vt-scan [status|file|url|domain|skill] [target]
./.agents/scripts/security-helper.sh ferret                              # AI CLI config scan
./.agents/scripts/security-helper.sh report [--format=sarif]
```

## Two-Pass Investigation Model

**Pass 1 — Reconnaissance**: Fast scan identifying all potential sources of untrusted input. Build a checklist: `SAST Recon on src/auth/handler.ts → Investigate data flow from userId:15, userInput:42`.

**Pass 2 — Investigation**: Trace each source to its sink. (1) Identify source (req.body, req.query). (2) Trace variable through calls and transforms. (3) Find sink (SQL query, HTML output, shell command). (4) Verify sanitization/escaping exists.

## Integrations

**Dependency scanning**: OSV-Scanner. Supported: npm/Yarn/pnpm, pip, Go, Cargo, Composer, Maven/Gradle.

**VirusTotal**: Advisory threat intelligence — SHA256 hash lookup against 70+ AV engines, domain/URL scanning. Rate-limited (16s between requests, max 8 per skill scan). Verdicts: SAFE, MALICIOUS, SUSPICIOUS, UNKNOWN. Does not block imports (Cisco Skill Scanner is the security gate).

API key setup: `aidevops secret set VIRUSTOTAL_MARCUSQUINN` (gopass) or add to `~/.config/aidevops/credentials.sh`.

**Ferret** (AI CLI config scanning): Detects prompt injection, jailbreaks, credential leaks, and backdoors in Claude Code, Cursor, Windsurf, Continue, Aider, Cline configs. 65+ rules across 9 threat categories.

```bash
npm install -g ferret-scan   # or: npx ferret-scan
# Docs: github.com/fubak/ferret-scan
# Custom rules: .ferretrc.json | Exclude known issues: ferret baseline create
```

## Output and Reporting

Reports saved to `.security-analysis/`:

```text
.security-analysis/
├── SECURITY_REPORT.md          # Human-readable report
├── security-report.json        # Machine-readable JSON
└── security-report.sarif       # SARIF format for CI/CD
```

Each finding includes: severity, file, lines, CWE, description, vulnerable code, and remediation with corrected code.

## Allowlisting and Exceptions

**Vulnerability allowlist** — `.security-analysis/vuln_allowlist.txt`:

```text
# Format: CWE-ID:file:line:reason
CWE-89:src/test/fixtures/sql.ts:15:Test fixture with intentional vulnerability
CWE-79:src/components/RawHtml.tsx:10:Sanitized by DOMPurify before render
```

**Inline suppression**:

```typescript
// security-ignore CWE-89: Input validated by middleware
const query = buildQuery(validatedInput);

/* security-ignore-start CWE-79 */
// Block of code with known safe HTML handling
/* security-ignore-end */
```

## CI/CD Integration

### GitHub Actions

```yaml
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }
- run: |
    ./.agents/scripts/security-helper.sh analyze branch
    ./.agents/scripts/security-helper.sh scan-deps
- uses: github/codeql-action/upload-sarif@v3
  with: { sarif_file: .security-analysis/security-report.sarif }
- run: grep -q '"severity": "critical"' .security-analysis/security-report.json && exit 1 || true
```

### Pre-commit Hook

```bash
./.agents/scripts/security-helper.sh analyze staged --severity-threshold=high || exit 1
```

## MCP Integration

```json
{
  "mcpServers": {
    "gemini-cli-security": { "command": "npx", "args": ["-y", "gemini-cli-security-mcp-server"] },
    "osv-scanner": { "command": "osv-scanner", "args": ["mcp"] }
  }
}
```

Tools: `find_line_numbers` (exact line numbers), `get_audit_scope` (git diff scope), `run_poc` (proof-of-concept exploits).

## Best Practices

**Development workflow**: Pre-commit (`analyze staged`) → PR review (`analyze branch`) → weekly full scans (`analyze full`) → post-dependency-change (`scan-deps`).

**Remediation SLAs**:

| Severity | SLA | Action |
|----------|-----|--------|
| Critical | 24h | Immediate fix, consider rollback |
| High | 7d | Prioritize in current sprint |
| Medium | 30d | Schedule for next sprint |
| Low | 90d | Address in maintenance cycle |

**False positive management**: Always verify before allowlisting. Include reason in allowlist entry. Prefer code fixes over suppressions.

## Tool Comparison

| Feature | This Tool | Shannon | Ferret | VirusTotal | Snyk Code | SonarCloud | CodeQL |
|---------|-----------|---------|--------|------------|-----------|------------|--------|
| AI-Powered | Yes | Yes | No | No | Partial | No | No |
| Taint Analysis | Yes | Yes (Pro) | No | No | Yes | Yes | Yes |
| Git History Scan | Yes | No | No | No | No | No | No |
| Full Codebase | Yes | Yes | Yes | No | Yes | Yes | Yes |
| Dependency Scan | Via OSV | No | No | No | Yes | Yes | No |
| File Hash / AV | No | No | No | Yes (70+) | No | No | No |
| Domain/URL Scan | No | No | No | Yes | No | No | No |
| LLM Safety | Yes | No | Yes | No | No | No | No |
| AI CLI Configs | Via Ferret | No | Yes | No | No | No | No |
| Prompt Injection | Yes | No | Yes | No | No | No | No |
| Exploit Validation | No | Yes | No | No | No | No | No |
| Local/Offline | Yes | Yes | Yes | No | No | No | Yes |
| MCP Integration | Yes | No | No | No | Yes | No | No |

## Troubleshooting

**"No files in scope"**: Check `git status` and `git diff --stat` — ensure changes exist to analyze.

**"OSV-Scanner not found"**: `go install github.com/google/osv-scanner/cmd/osv-scanner@latest` or `brew install osv-scanner`.

**"Analysis timeout"**: Target specific paths or use `analyze branch` instead of `analyze full`.

**"Too many false positives"**: Use `vuln_allowlist.txt` or `ferret baseline create` for AI config scans.

## Resources

- [OSV-Scanner](https://github.com/google/osv-scanner) | [OSV Database](https://osv.dev/)
- [Ferret Scan](https://github.com/fubak/ferret-scan)
- [VirusTotal](https://www.virustotal.com/) | [VT API v3](https://docs.virustotal.com/reference/overview)
- [CWE Database](https://cwe.mitre.org/) | [OWASP Top 10](https://owasp.org/Top10/)
- [Gemini CLI Security](https://github.com/gemini-cli-extensions/security)
