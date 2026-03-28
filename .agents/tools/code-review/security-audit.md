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
- **Tools**: `security-helper.sh scan-deps` (OSV-Scanner), `secretlint-helper.sh` (credentials), `prompt-guard-helper.sh` (injection). See `tools/security/prompt-injection-defender.md`.
- **Cleanup**: Always remove cloned repos after audit

**Always:** secrets (§3.1), hardcoded secrets (§3.3), insecure HTTP URLs (§3.11), security automation (§3.13).  
**Conditional:** deps (§3.2, lockfile), unsafe code (§3.4, per language), GH Actions (§3.5), Docker (§3.6), shell (§3.7), XSS (§3.8), CORS (§3.9), auth/rate-limit (§3.10), prompt injection (§3.12, AI code).

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

### 3. Scan Categories (run all applicable; parallelize independent scans)

#### 3.1 Secrets (Always)

```bash
npx secretlint "**/*" --secretlintrc '{"rules":[{"id":"@secretlint/secretlint-rule-preset-recommend"}]}' 2>/dev/null || true
rg -in '(api[_-]?key|api[_-]?secret|access[_-]?token|auth[_-]?token|secret[_-]?key|private[_-]?key|password\s*=|passwd\s*=|credentials)' \
  --glob '!{*.lock,*.sum,node_modules/**,vendor/**,target/**,.git/**}' -l
```

#### 3.2 Dependency Vulnerabilities (Lockfile present)

Cargo: `cargo audit` · npm: `npm audit --json` · pip: `pip audit -r requirements.txt` · Go: `govulncheck ./...` · Any: `osv-scanner --lockfile=<path>`

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
rg -n 'uses:\s+[^#]+@(v\d|main|master|latest)' --glob '*.{yml,yaml}' -g '.github/**'  # Unpinned (HIGH)
rg -L '^permissions:' --glob '*.{yml,yaml}' -g '.github/**'                             # Missing permissions (HIGH)
rg -n 'echo.*\$\{\{\s*secrets\.' --glob '*.{yml,yaml}' -g '.github/**'                 # Secrets in logs
rg -on 'uses:\s+([^/]+/[^@]+)@' --glob '*.{yml,yaml}' -g '.github/**' -r '$1' | \
  grep -v -E '^[^:]+:(actions|github)/' | sort -u                                       # Third-party actions
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
rg -n 'innerHTML\s*=|dangerouslySetInnerHTML|v-html|document\.write\s*\(|\[innerHtml\]' --glob '*.{js,ts,jsx,tsx,vue,html}'
```

#### 3.9 CORS (Web server code present)

```bash
rg -in 'cors|access-control-allow-origin|origin.*\*|Access-Control-Allow-Credentials.*true' --glob '*.{js,ts,py,go,rs,rb,java}'
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

For aidevops projects, verify `prompt-guard-helper.sh` integration.

#### 3.13 Security Automation (Always)

```bash
ls .github/dependabot.yml renovate.json .renovaterc 2>/dev/null
rg -l '(codeql|snyk|trivy|grype|osv-scanner|semgrep)' --glob '*.{yml,yaml}' -g '.github/**' 2>/dev/null
ls SECURITY.md .github/SECURITY.md 2>/dev/null
```

### 4. Security Architecture + Cleanup

Review: auth model (API keys/OAuth/JWT/session), authorization (RBAC/ABAC), input validation, error handling (no internal detail leakage), logging (no sensitive data), encryption (TLS enforced, data at rest).

```bash
rm -rf "$CLONE_DIR"  # Always remove cloned repo after audit
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

### Section Results
One row per category (1–13 from Quick Reference + 14: Security Architecture). Status: `PASS/FAIL/WARN/SKIP`.

### Recommendations
1. **{Priority}**: {actionable recommendation}
````

## Severity and Assessment

**Severity:** CRITICAL = active credential exposure, RCE, no auth on sensitive endpoints · HIGH = unpinned GH Actions, missing USER in Docker, eval with user input, no rate limiting on auth · MEDIUM = excessive `.unwrap()`, missing Dependabot, wildcard CORS, http:// in production · LOW = missing SECURITY.md, no multi-stage Docker, minor ShellCheck · INFO = best practice suggestions.

| Rating | Criteria |
|--------|----------|
| **Excellent** | 0 HIGH+, 0-2 MEDIUM, comprehensive security automation |
| **Strong** | 0 HIGH+, 3-5 MEDIUM, some security automation |
| **Good** | 0 CRITICAL, 1-2 HIGH, reasonable security practices |
| **Needs Work** | 0 CRITICAL, 3+ HIGH or 10+ MEDIUM |
| **Critical Issues** | Any CRITICAL finding, or 5+ HIGH findings |
