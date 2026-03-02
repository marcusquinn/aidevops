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
- **Purpose**: Comprehensive security audit of external repositories by URL
- **Workspace**: `~/.aidevops/.agent-workspace/tmp/security-audit/`
- **Reuses**: `security-helper.sh` (scan-deps), `secretlint-helper.sh` (secrets)
- **Cleanup**: Always remove cloned repos after audit
- **Output**: Structured markdown report with severity table

**Audit Categories** (run all applicable):

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

### 1. Clone and Setup

Clone the target repository with minimal history:

```bash
AUDIT_DIR="$HOME/.aidevops/.agent-workspace/tmp/security-audit"
mkdir -p "$AUDIT_DIR"
REPO_NAME=$(basename "$REPO_URL" .git)
CLONE_DIR="$AUDIT_DIR/$REPO_NAME"

# Clean any previous clone
rm -rf "$CLONE_DIR"

# Shallow clone for speed
git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
```

### 2. Language and Framework Detection

Detect the project's technology stack by checking for manifest files:

```bash
# Run these checks in the cloned directory
cd "$CLONE_DIR"

# Check for language/framework indicators
ls Cargo.toml Cargo.lock 2>/dev/null          # Rust
ls package.json package-lock.json 2>/dev/null  # Node.js
ls requirements.txt Pipfile pyproject.toml 2>/dev/null  # Python
ls go.mod go.sum 2>/dev/null                   # Go
ls Dockerfile docker-compose.yml 2>/dev/null   # Docker
ls -d .github/workflows/ 2>/dev/null           # GitHub Actions
fd -e sh --max-depth 3 2>/dev/null | head -5   # Shell scripts
fd -e rs --max-depth 3 2>/dev/null | head -5   # Rust source
fd -e js -e ts --max-depth 3 2>/dev/null | head -5  # JS/TS source
fd -e py --max-depth 3 2>/dev/null | head -5   # Python source
fd -e go --max-depth 3 2>/dev/null | head -5   # Go source
```

Record detected languages for the report header.

### 3. Scan Categories

Run all applicable categories. Use `rg` (ripgrep) for pattern matching. Run independent scans in parallel where possible.

#### 3.1 Secrets and Credentials (Always)

```bash
# Use secretlint if available
npx secretlint "**/*" --secretlintrc '{"rules":[{"id":"@secretlint/secretlint-rule-preset-recommend"}]}' 2>/dev/null || true

# Manual pattern scan for common secrets
rg -in '(api[_-]?key|api[_-]?secret|access[_-]?token|auth[_-]?token|secret[_-]?key|private[_-]?key|password\s*=|passwd\s*=|credentials)' \
  --glob '!{*.lock,*.sum,node_modules/**,vendor/**,target/**,.git/**}' \
  -l
```

Report each finding with file:line reference.

#### 3.2 Dependency Vulnerabilities (When lockfile present)

Run the appropriate audit tool based on detected package manager:

| Package Manager | Command |
|----------------|---------|
| Cargo (Rust) | `cargo audit` (if installed) |
| npm | `npm audit --json 2>/dev/null` |
| pip | `pip audit -r requirements.txt 2>/dev/null` |
| Go | `govulncheck ./... 2>/dev/null` |
| Any | `osv-scanner --lockfile=<path> 2>/dev/null` |

#### 3.3 Hardcoded Secret Patterns (Always)

```bash
# AWS keys
rg -in 'AKIA[0-9A-Z]{16}' --glob '!{*.lock,*.sum,.git/**}'

# Private keys
rg -l '-----BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----' --glob '!{*.lock,.git/**}'

# Connection strings
rg -in '(mongodb|postgres|mysql|redis)://[^"'\''[:space:]]+' --glob '!{*.lock,.git/**}'

# Generic high-entropy strings in assignments
rg -in '(token|secret|password|key)\s*[:=]\s*["\x27][A-Za-z0-9+/=]{20,}["\x27]' \
  --glob '!{*.lock,*.sum,node_modules/**,.git/**}'
```

#### 3.4 Unsafe Code Patterns (Per language)

**Rust:**

```bash
rg -n 'unsafe\s*\{' --glob '*.rs'
rg -n 'Command::new|std::process::Command' --glob '*.rs'
rg -n '\.unwrap\(\)' --glob '*.rs' | head -20  # Excessive unwrap = crash risk
```

**JavaScript/TypeScript:**

```bash
rg -n '\beval\s*\(' --glob '*.{js,ts,jsx,tsx}'
rg -n 'new Function\s*\(' --glob '*.{js,ts,jsx,tsx}'
rg -n 'child_process|exec\s*\(|execSync\s*\(' --glob '*.{js,ts,jsx,tsx}'
rg -n 'innerHTML\s*=' --glob '*.{js,ts,jsx,tsx,html}'
rg -n 'dangerouslySetInnerHTML' --glob '*.{js,ts,jsx,tsx}'
rg -n 'v-html' --glob '*.vue'
```

**Python:**

```bash
rg -n '\beval\s*\(|\bexec\s*\(' --glob '*.py'
rg -n 'subprocess\.(call|run|Popen|check_output)\s*\(' --glob '*.py'
rg -n 'os\.system\s*\(' --glob '*.py'
rg -n 'pickle\.loads?\s*\(' --glob '*.py'
rg -n '__import__\s*\(' --glob '*.py'
```

**Go:**

```bash
rg -n 'exec\.Command\s*\(' --glob '*.go'
rg -n 'os/exec' --glob '*.go'
rg -n 'template\.HTML\s*\(' --glob '*.go'  # Unescaped HTML
```

#### 3.5 GitHub Actions Supply Chain (When `.github/workflows/` present)

This is a critical category. Check for:

**SHA pinning:**

```bash
# Find actions NOT pinned to SHA (using @v1, @v2, @main, etc.)
rg -n 'uses:\s+[^#]+@(v\d|main|master|latest)' --glob '*.{yml,yaml}' -g '.github/**'

# Find actions properly pinned to SHA
rg -n 'uses:\s+[^#]+@[a-f0-9]{40}' --glob '*.{yml,yaml}' -g '.github/**'
```

**Permissions:**

```bash
# Check for workflow-level permissions block
rg -n '^permissions:' --glob '*.{yml,yaml}' -g '.github/**'

# Check for overly permissive permissions
rg -n 'permissions:\s*write-all' --glob '*.{yml,yaml}' -g '.github/**'
rg -n 'contents:\s*write' --glob '*.{yml,yaml}' -g '.github/**'
```

**Secret usage:**

```bash
# Find secret references
rg -n '\$\{\{\s*secrets\.' --glob '*.{yml,yaml}' -g '.github/**'

# Check for secrets in run commands (potential exposure)
rg -n 'echo.*\$\{\{\s*secrets\.' --glob '*.{yml,yaml}' -g '.github/**'
```

**Third-party action risk:**

```bash
# List all third-party actions (not actions/ or github/)
rg -on 'uses:\s+([^/]+/[^@]+)@' --glob '*.{yml,yaml}' -g '.github/**' -r '$1' | \
  grep -v -E '^[^:]+:(actions|github)/' | sort -u
```

#### 3.6 Docker Security (When `Dockerfile` present)

```bash
# Check for USER directive (running as non-root)
rg -n '^USER ' Dockerfile* docker/Dockerfile* 2>/dev/null

# Check base image (prefer minimal: alpine, distroless, scratch)
rg -n '^FROM ' Dockerfile* docker/Dockerfile* 2>/dev/null

# Check for secrets in build args
rg -in '(ARG|ENV).*(password|secret|key|token)' Dockerfile* docker/Dockerfile* 2>/dev/null

# Check for multi-stage builds
rg -c '^FROM ' Dockerfile* docker/Dockerfile* 2>/dev/null  # >1 = multi-stage

# Check for COPY --chown (proper file ownership)
rg -n 'COPY --chown' Dockerfile* docker/Dockerfile* 2>/dev/null

# Check for .dockerignore
ls .dockerignore 2>/dev/null
```

#### 3.7 Shell Script Security (When `.sh` files present)

```bash
# Run ShellCheck if available
fd -e sh --max-depth 5 -x shellcheck {} 2>/dev/null | head -50

# Check for common shell security issues
rg -n 'eval\s' --glob '*.sh'
rg -n 'curl.*\|\s*(bash|sh)' --glob '*.sh'  # Pipe to shell
rg -n '\$\{.*:-\}' --glob '*.sh' | head -10  # Unquoted variable defaults
```

#### 3.8 XSS and Frontend Patterns (When JS/HTML present)

```bash
rg -n 'innerHTML\s*=' --glob '*.{js,ts,jsx,tsx,html}'
rg -n 'dangerouslySetInnerHTML' --glob '*.{js,ts,jsx,tsx}'
rg -n 'v-html' --glob '*.vue'
rg -n 'document\.write\s*\(' --glob '*.{js,ts,html}'
rg -n '\[innerHtml\]' --glob '*.{ts,html}'  # Angular
```

#### 3.9 CORS Configuration (When web server code present)

```bash
rg -in 'cors|access-control-allow-origin' --glob '*.{js,ts,py,go,rs,rb,java}'
rg -in 'origin.*\*' --glob '*.{js,ts,py,go,rs,rb,java}'  # Wildcard origin
rg -in 'Access-Control-Allow-Credentials.*true' --glob '*.{js,ts,py,go,rs}'
```

#### 3.10 Auth and Rate Limiting (When API server code present)

```bash
# Auth middleware
rg -in '(auth|authenticate|authorize|middleware|guard)' \
  --glob '*.{js,ts,py,go,rs}' -l | head -10

# Rate limiting
rg -in '(rate.?limit|throttle|limiter)' --glob '*.{js,ts,py,go,rs}' -l

# JWT handling
rg -in '(jwt|jsonwebtoken|jose)' --glob '*.{js,ts,py,go,rs}' -l

# Session management
rg -in '(session|cookie.*secure|httponly|samesite)' --glob '*.{js,ts,py,go,rs}' -l
```

#### 3.11 Insecure HTTP URLs (Always)

```bash
# Find http:// in source code (excluding lockfiles, vendor, docs)
rg -n 'http://' \
  --glob '!{*.lock,*.sum,node_modules/**,vendor/**,target/**,.git/**,*.md,LICENSE*}' \
  --glob '*.{js,ts,py,go,rs,rb,java,yaml,yml,toml,json,sh}' | \
  grep -v 'localhost\|127\.0\.0\.1\|0\.0\.0\.0\|example\.com' | head -20
```

#### 3.12 Prompt Injection Patterns (When AI/agent code present)

If the project processes untrusted content through AI/LLM pipelines (user uploads, web scraping, API responses, chat inputs), check for prompt injection defenses:

```bash
# Check for prompt injection scanning in the codebase
rg -in '(prompt.?inject|prompt.?guard|content.?scan|injection.?detect)' \
  --glob '*.{js,ts,py,go,rs,sh,yaml,yml}' -l

# Check for untrusted content ingestion without scanning
rg -in '(webfetch|fetch|requests\.get|urllib|curl)' \
  --glob '*.{js,ts,py,go,rs,sh}' -l | head -10

# Check for LLM/AI framework usage (indicates prompt injection risk)
rg -in '(openai|anthropic|langchain|llama|ollama|ai\.run|completion)' \
  --glob '*.{js,ts,py,go,rs}' -l | head -10
```

For aidevops projects, verify `prompt-guard-helper.sh` integration. See `tools/security/prompt-injection-defender.md` for defense patterns and integration guidance.

#### 3.13 Security Automation (Always)

```bash
# Dependabot
ls .github/dependabot.yml .github/dependabot.yaml 2>/dev/null

# Renovate
ls renovate.json .renovaterc .renovaterc.json 2>/dev/null

# Security scanning in CI
rg -l '(codeql|snyk|trivy|grype|osv-scanner|semgrep)' \
  --glob '*.{yml,yaml}' -g '.github/**' 2>/dev/null

# Security policy
ls SECURITY.md .github/SECURITY.md 2>/dev/null
```

### 4. Security Architecture Assessment

After running automated scans, assess the overall security architecture:

- **Authentication model**: How does the project handle auth? (API keys, OAuth, JWT, session-based)
- **Authorization model**: RBAC, ABAC, capability-based?
- **Input validation**: Is there a consistent validation layer?
- **Error handling**: Do errors leak internal details?
- **Logging**: Is sensitive data excluded from logs?
- **Encryption**: TLS enforced? Data at rest encrypted?

This is a qualitative assessment based on reading the codebase structure, not automated scanning.

### 5. Cleanup

Always remove the cloned repository after the audit:

```bash
rm -rf "$CLONE_DIR"
echo "Cleaned up: $CLONE_DIR"
```

## Report Template

Use this exact structure for the audit report:

````markdown
## Security Audit Report: {repo-name}

**Repository:** {url}
**Audit Date:** {ISO date}
**Languages:** {detected languages}
**Overall Assessment:** {Excellent | Strong | Good | Needs Work | Critical Issues}

### 1. Secrets and Credentials -- **{PASS/FAIL/WARN}**

{findings with file:line references, or "No issues found"}

### 2. Dependency Vulnerabilities -- **{PASS/FAIL/WARN/SKIP}**

{findings or "No known vulnerabilities" or "No lockfile found (SKIP)"}

### 3. Unsafe Code Patterns -- **{PASS/FAIL/WARN}**

{language-specific findings}

### 4. GitHub Actions Supply Chain -- **{PASS/FAIL/WARN/SKIP}**

{SHA pinning status, permissions, secret usage, or "No workflows found (SKIP)"}

### 5. Docker Security -- **{PASS/FAIL/WARN/SKIP}**

{USER directive, base image, secrets in build, or "No Dockerfile found (SKIP)"}

### 6. Shell Script Security -- **{PASS/FAIL/WARN/SKIP}**

{ShellCheck findings or "No shell scripts found (SKIP)"}

### 7. Frontend Security (XSS) -- **{PASS/FAIL/WARN/SKIP}**

{innerHTML, dangerouslySetInnerHTML findings, or "No frontend code found (SKIP)"}

### 8. CORS Configuration -- **{PASS/FAIL/WARN/SKIP}**

{wildcard origins, credentials with wildcard, or "No CORS configuration found (SKIP)"}

### 9. Auth and Rate Limiting -- **{PASS/FAIL/WARN/SKIP}**

{middleware presence, JWT handling, rate limiting, or "No API server code found (SKIP)"}

### 10. Insecure HTTP URLs -- **{PASS/WARN}**

{http:// references in source code}

### 11. Prompt Injection Defense -- **{PASS/FAIL/WARN/SKIP}**

{prompt injection scanning presence, untrusted content handling, or "No AI/agent code found (SKIP)"}

### 12. Security Automation -- **{PASS/FAIL/WARN}**

{Dependabot/Renovate, CI scanning, SECURITY.md}

### 13. Security Architecture -- **{assessment}**

{qualitative assessment of auth, validation, error handling}

---

### Summary of Findings

| Priority | Finding | Location | Category |
|----------|---------|----------|----------|
| HIGH | {description} | {file:line} | {category} |
| MEDIUM | {description} | {file:line} | {category} |
| LOW | {description} | {file:line} | {category} |

### Recommendations

1. **{Priority}**: {actionable recommendation}
2. ...
````

## Severity Definitions

| Severity | Criteria |
|----------|----------|
| **CRITICAL** | Active credential exposure, RCE vulnerability, no auth on sensitive endpoints |
| **HIGH** | Unpinned GitHub Actions, missing USER in Docker, eval with user input, no rate limiting on auth |
| **MEDIUM** | Excessive `.unwrap()`, missing Dependabot, wildcard CORS, http:// URLs in production code |
| **LOW** | Missing SECURITY.md, no multi-stage Docker build, minor ShellCheck warnings |
| **INFO** | Observations, best practice suggestions, architecture notes |

## Overall Assessment Criteria

| Rating | Criteria |
|--------|----------|
| **Excellent** | 0 HIGH+, 0-2 MEDIUM, comprehensive security automation |
| **Strong** | 0 HIGH+, 3-5 MEDIUM, some security automation |
| **Good** | 0 CRITICAL, 1-2 HIGH, reasonable security practices |
| **Needs Work** | 0 CRITICAL, 3+ HIGH or 10+ MEDIUM |
| **Critical Issues** | Any CRITICAL finding, or 5+ HIGH findings |

## Integration with Existing Tools

This audit reuses existing aidevops security infrastructure where applicable:

- **`security-helper.sh scan-deps`**: For dependency vulnerability scanning via OSV-Scanner
- **`secretlint-helper.sh`**: For credential detection
- **`prompt-guard-helper.sh`**: For prompt injection pattern scanning (chat, content, stdin). See `tools/security/prompt-injection-defender.md` for integration patterns.
- **ShellCheck**: For shell script analysis (via `linters-local.sh` patterns)

The audit adds categories not covered by existing commands: GitHub Actions supply chain, Docker security, CORS, auth/rate limiting, prompt injection defense, and the structured severity report.
