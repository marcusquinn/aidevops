---
description: Comprehensive security audit methodology for external repositories
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
mcp:
  - secretlint
  - socket
---

# Security Audit - External Repository Methodology

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/security-audit <repo-url>`
- **Workspace**: `~/.aidevops/.agent-workspace/tmp/security-audit/`
- **Reuses**: `security-helper.sh` (scan-deps), `secretlint-helper.sh` (secrets)
- **Cleanup**: Always remove cloned repos after audit

**Audit Categories:**

| Category | Applies When |
|----------|-------------|
| Secrets/credentials | Always |
| Dependency vulnerabilities | Lockfile present |
| Hardcoded secret patterns | Always |
| Unsafe code patterns | Per language |
| GitHub Actions supply chain | `.github/workflows/` present |
| Docker security | `Dockerfile` present |
| Shell script security | `.sh` files present |
| XSS / frontend patterns | JS/HTML present |
| CORS configuration | Web server code present |
| Auth / rate limiting | API server code present |
| Insecure HTTP URLs | Always |
| Prompt injection patterns | AI/agent code present |
| Security automation (Dependabot) | Always |

<!-- AI-CONTEXT-END -->

## Workflow

### 1. Clone

```bash
AUDIT_DIR="$HOME/.aidevops/.agent-workspace/tmp/security-audit"
mkdir -p "$AUDIT_DIR"
REPO_NAME=$(basename "$REPO_URL" .git)
CLONE_DIR="$AUDIT_DIR/$REPO_NAME"
rm -rf "$CLONE_DIR"
git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
```

### 2. Detect Stack

```bash
cd "$CLONE_DIR"
ls Cargo.toml package.json requirements.txt go.mod Dockerfile .github/workflows/ 2>/dev/null
fd -e sh -e rs -e js -e ts -e py -e go --max-depth 3 2>/dev/null | head -5
```

### 3. Scan Categories

Run all applicable. Use `rg` for patterns. Parallelize independent scans.

#### 3.1 Secrets (Always)

```bash
npx secretlint "**/*" --secretlintrc '{"rules":[{"id":"@secretlint/secretlint-rule-preset-recommend"}]}' 2>/dev/null || true
rg -in '(api[_-]?key|api[_-]?secret|access[_-]?token|auth[_-]?token|secret[_-]?key|private[_-]?key|password\s*=|passwd\s*=|credentials)' \
  --glob '!{*.lock,*.sum,node_modules/**,vendor/**,target/**,.git/**}' -l
```

#### 3.2 Dependency Vulnerabilities (Lockfile present)

| Package Manager | Command |
|----------------|---------|
| Cargo | `cargo audit` |
| npm | `npm audit --json 2>/dev/null` |
| pip | `pip audit -r requirements.txt 2>/dev/null` |
| Go | `govulncheck ./... 2>/dev/null` |
| Any | `osv-scanner --lockfile=<path> 2>/dev/null` |

#### 3.3 Hardcoded Secrets (Always)

```bash
rg -in 'AKIA[0-9A-Z]{16}' --glob '!{*.lock,*.sum,.git/**}'
rg -l '-----BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----' --glob '!{*.lock,.git/**}'
rg -in '(mongodb|postgres|mysql|redis)://[^"'\''[:space:]]+' --glob '!{*.lock,.git/**}'
rg -in '(token|secret|password|key)\s*[:=]\s*["\x27][A-Za-z0-9+/=]{20,}["\x27]' \
  --glob '!{*.lock,*.sum,node_modules/**,.git/**}'
```

#### 3.4 Unsafe Code Patterns (Per language)

**Rust:** `rg -n 'unsafe\s*\{|Command::new|\.unwrap\(\)' --glob '*.rs'`

**JS/TS:** `rg -n '\beval\s*\(|new Function\s*\(|child_process|exec\s*\(|innerHTML\s*=|dangerouslySetInnerHTML|v-html' --glob '*.{js,ts,jsx,tsx,vue,html}'`

**Python:** `rg -n '\beval\s*\(|\bexec\s*\(|subprocess\.|os\.system|pickle\.loads?|__import__' --glob '*.py'`

**Go:** `rg -n 'exec\.Command|os/exec|template\.HTML' --glob '*.go'`

#### 3.5 GitHub Actions Supply Chain (`.github/workflows/` present)

```bash
# Unpinned actions (HIGH risk)
rg -n 'uses:\s+[^#]+@(v\d|main|master|latest)' --glob '*.{yml,yaml}' -g '.github/**'
# Workflows missing permissions block (HIGH risk)
rg -L '^permissions:' --glob '*.{yml,yaml}' -g '.github/**'
# Secrets echoed to logs
rg -n 'echo.*\$\{\{\s*secrets\.' --glob '*.{yml,yaml}' -g '.github/**'
# Third-party actions list
rg -on 'uses:\s+([^/]+/[^@]+)@' --glob '*.{yml,yaml}' -g '.github/**' -r '$1' | \
  grep -v -E '^[^:]+:(actions|github)/' | sort -u
```

#### 3.6 Docker Security (`Dockerfile` present)

```bash
rg -n '^USER |^FROM |^COPY --chown' Dockerfile* docker/Dockerfile* 2>/dev/null
rg -in '(ARG|ENV).*(password|secret|key|token)' Dockerfile* 2>/dev/null
rg -c '^FROM ' Dockerfile* 2>/dev/null  # >1 = multi-stage
ls .dockerignore 2>/dev/null
```

#### 3.7 Shell Script Security (`.sh` files present)

```bash
fd -e sh --max-depth 5 -x shellcheck {} 2>/dev/null | head -50
rg -n 'eval\s|curl.*\|\s*(bash|sh)' --glob '*.sh'
```

#### 3.8 XSS / Frontend (JS/HTML present)

```bash
rg -n 'innerHTML\s*=|dangerouslySetInnerHTML|v-html|document\.write\s*\(|\[innerHtml\]' \
  --glob '*.{js,ts,jsx,tsx,vue,html}'
```

#### 3.9 CORS (Web server code present)

```bash
rg -in 'cors|access-control-allow-origin|origin.*\*|Access-Control-Allow-Credentials.*true' \
  --glob '*.{js,ts,py,go,rs,rb,java}'
```

#### 3.10 Auth and Rate Limiting (API server present)

```bash
rg -in '(auth|authenticate|authorize|middleware|guard)' --glob '*.{js,ts,py,go,rs}' -l | head -10
rg -in '(rate.?limit|throttle|limiter|jwt|jsonwebtoken|session|cookie.*secure|httponly|samesite)' \
  --glob '*.{js,ts,py,go,rs}' -l
```

#### 3.11 Insecure HTTP URLs (Always)

```bash
rg -n 'http://' \
  --glob '!{*.lock,*.sum,node_modules/**,vendor/**,target/**,.git/**,*.md,LICENSE*}' \
  --glob '*.{js,ts,py,go,rs,rb,java,yaml,yml,toml,json,sh}' | \
  grep -v 'localhost\|127\.0\.0\.1\|0\.0\.0\.0\|example\.com' | head -20
```

#### 3.12 Prompt Injection (AI/agent code present)

```bash
rg -in '(prompt.?inject|prompt.?guard|content.?scan|injection.?detect)' \
  --glob '*.{js,ts,py,go,rs,sh,yaml,yml}' -l
rg -in '(openai|anthropic|langchain|llama|ollama|ai\.run|completion)' \
  --glob '*.{js,ts,py,go,rs,sh}' -l | head -10
```

For aidevops projects, verify `prompt-guard-helper.sh` integration. See `tools/security/prompt-injection-defender.md`.

#### 3.13 Security Automation (Always)

```bash
ls .github/dependabot.yml renovate.json .renovaterc 2>/dev/null
rg -l '(codeql|snyk|trivy|grype|osv-scanner|semgrep)' --glob '*.{yml,yaml}' -g '.github/**' 2>/dev/null
ls SECURITY.md .github/SECURITY.md 2>/dev/null
```

### 4. Security Architecture Assessment (Qualitative)

Review: auth model (API keys/OAuth/JWT/session), authorization (RBAC/ABAC), input validation layer, error handling (no internal detail leakage), logging (no sensitive data), encryption (TLS enforced, data at rest).

### 5. Cleanup

```bash
rm -rf "$CLONE_DIR"
```

## Report Template

````markdown
## Security Audit Report: {repo-name}

**Repository:** {url}  **Audit Date:** {ISO date}  **Languages:** {detected}
**Overall Assessment:** {Excellent | Strong | Good | Needs Work | Critical Issues}

### Summary of Findings

| Priority | Finding | Location | Category |
|----------|---------|----------|----------|
| HIGH | {description} | {file:line} | {category} |
| MEDIUM | ... | ... | ... |
| LOW | ... | ... | ... |

### Section Results

| # | Category | Status | Notes |
|---|----------|--------|-------|
| 1 | Secrets/Credentials | PASS/FAIL/WARN | |
| 2 | Dependency Vulnerabilities | PASS/FAIL/WARN/SKIP | |
| 3 | Hardcoded Secret Patterns | PASS/FAIL/WARN | |
| 4 | Unsafe Code Patterns | PASS/FAIL/WARN | |
| 5 | GitHub Actions Supply Chain | PASS/FAIL/WARN/SKIP | |
| 6 | Docker Security | PASS/FAIL/WARN/SKIP | |
| 7 | Shell Script Security | PASS/FAIL/WARN/SKIP | |
| 8 | Frontend Security (XSS) | PASS/FAIL/WARN/SKIP | |
| 9 | CORS Configuration | PASS/FAIL/WARN/SKIP | |
| 10 | Auth and Rate Limiting | PASS/FAIL/WARN/SKIP | |
| 11 | Insecure HTTP URLs | PASS/WARN | |
| 12 | Prompt Injection Defense | PASS/FAIL/WARN/SKIP | |
| 13 | Security Automation | PASS/FAIL/WARN | |
| 14 | Security Architecture | {assessment} | |

### Recommendations

1. **{Priority}**: {actionable recommendation}
````

## Severity Definitions

| Severity | Criteria |
|----------|----------|
| **CRITICAL** | Active credential exposure, RCE, no auth on sensitive endpoints |
| **HIGH** | Unpinned GitHub Actions, missing USER in Docker, eval with user input, no rate limiting on auth |
| **MEDIUM** | Excessive `.unwrap()`, missing Dependabot, wildcard CORS, http:// in production code |
| **LOW** | Missing SECURITY.md, no multi-stage Docker build, minor ShellCheck warnings |
| **INFO** | Best practice suggestions, architecture notes |

## Overall Assessment Criteria

| Rating | Criteria |
|--------|----------|
| **Excellent** | 0 HIGH+, 0-2 MEDIUM, comprehensive security automation |
| **Strong** | 0 HIGH+, 3-5 MEDIUM, some security automation |
| **Good** | 0 CRITICAL, 1-2 HIGH, reasonable security practices |
| **Needs Work** | 0 CRITICAL, 3+ HIGH or 10+ MEDIUM |
| **Critical Issues** | Any CRITICAL finding, or 5+ HIGH findings |

## Integration with Existing Tools

- **`security-helper.sh scan-deps`**: Dependency vulnerability scanning via OSV-Scanner
- **`secretlint-helper.sh`**: Credential detection
- **`prompt-guard-helper.sh`**: Prompt injection pattern scanning. See `tools/security/prompt-injection-defender.md`.
- **ShellCheck**: Shell script analysis (via `linters-local.sh` patterns)
