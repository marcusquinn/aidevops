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
- **Output**: `.security-analysis/` — `SECURITY_REPORT.md`, `security-report.json`, `security-report.sarif`
- **Severity**: critical > high > medium > low > info
- **Benchmarks**: 90% precision, 93% recall (OpenSSF CVE Benchmark)
- **Integrations**: OSV-Scanner (deps), Secretlint (secrets), Ferret (AI configs), VirusTotal (file/URL/domain), Shannon (pentesting), Snyk/SonarCloud/CodeQL (optional)
- **MCP**: `gemini-cli-security` — `find_line_numbers`, `get_audit_scope`, `run_poc`

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
./.agents/scripts/security-helper.sh history 50          # or abc123..def456, --since=, --author=
./.agents/scripts/security-helper.sh scan-deps [path]
./.agents/scripts/security-helper.sh skill-scan          # Cisco + VirusTotal advisory
./.agents/scripts/security-helper.sh vt-scan [status|file|url|domain|skill] [target]
./.agents/scripts/security-helper.sh ferret              # AI CLI config scan
./.agents/scripts/security-helper.sh report [--format=sarif]
```

**Workflow**: Pre-commit (`analyze staged`) → PR review (`analyze branch`) → weekly (`analyze full`) → post-dep-change (`scan-deps`).

## Two-Pass Investigation

**Pass 1 — Recon**: Fast scan; identify all untrusted input sources. Build checklist: `SAST Recon on src/auth/handler.ts → Investigate data flow from userId:15, userInput:42`.

**Pass 2 — Trace**: For each source: (1) identify origin (req.body, req.query), (2) trace through calls/transforms, (3) find sink (SQL query, HTML output, shell command), (4) verify sanitization.

## Integrations

**OSV-Scanner** (deps): npm/Yarn/pnpm, pip, Go, Cargo, Composer, Maven/Gradle. [Docs](https://github.com/google/osv-scanner) | [OSV DB](https://osv.dev/)

**VirusTotal**: SHA256 hash lookup against 70+ AV engines, domain/URL scanning. Rate-limited (16s between requests, max 8 per skill scan). Verdicts: SAFE, MALICIOUS, SUSPICIOUS, UNKNOWN. Does not block imports (Cisco Skill Scanner is the security gate). API key: `aidevops secret set VIRUSTOTAL_MARCUSQUINN` (gopass) or `~/.config/aidevops/credentials.sh`. [API v3](https://docs.virustotal.com/reference/overview)

**Ferret** (AI CLI configs): Detects prompt injection, jailbreaks, credential leaks, backdoors in Claude Code, Cursor, Windsurf, Continue, Aider, Cline. 65+ rules, 9 threat categories. [Docs](https://github.com/fubak/ferret-scan)

```bash
npm install -g ferret-scan   # or: npx ferret-scan
# Custom rules: .ferretrc.json | Exclude known issues: ferret baseline create
```

**Shannon** (pentesting): Taint analysis (Pro), exploit validation. **Snyk Code** / **SonarCloud** / **CodeQL**: dependency scanning, taint analysis, CI/CD integration. [CWE DB](https://cwe.mitre.org/) | [OWASP Top 10](https://owasp.org/Top10/)

**Gemini CLI Security MCP**: `find_line_numbers`, `get_audit_scope`, `run_poc`. Config: `"gemini-cli-security": { "command": "npx", "args": ["-y", "gemini-cli-security-mcp-server"] }`, `"osv-scanner": { "command": "osv-scanner", "args": ["mcp"] }`.

## Allowlisting

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

Always verify before allowlisting. Include reason. Prefer code fixes over suppressions.

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

## Remediation SLAs

| Severity | SLA | Action |
|----------|-----|--------|
| Critical | 24h | Immediate fix, consider rollback |
| High | 7d | Prioritize in current sprint |
| Medium | 30d | Schedule for next sprint |
| Low | 90d | Address in maintenance cycle |

## Troubleshooting

- **"No files in scope"**: Check `git status` and `git diff --stat`.
- **"OSV-Scanner not found"**: `go install github.com/google/osv-scanner/cmd/osv-scanner@latest` or `brew install osv-scanner`.
- **"Analysis timeout"**: Target specific paths or use `analyze branch` instead of `analyze full`.
- **"Too many false positives"**: Use `vuln_allowlist.txt` or `ferret baseline create`.
