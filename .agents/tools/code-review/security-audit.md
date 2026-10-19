---
description: Security audit methodology for external repositories
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Security Audit - External Repository Methodology

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/security-audit <repo-url>`
- **Workspace**: `~/.aidevops/.agent-workspace/tmp/security-audit/`
- **Tools**: `security-helper.sh scan-deps` (OSV-Scanner), `secretlint-helper.sh` (credentials), `prompt-guard-helper.sh` (injection). See `tools/security/prompt-injection-defender.md`.
- **Cleanup**: Always remove cloned repos after audit

**Audit categories** (run all applicable, parallelize independent scans):

| # | Category | When |
|---|----------|------|
| 1 | Secrets & hardcoded credentials | Always |
| 2 | Dependency vulnerabilities | Lockfile present |
| 3 | Unsafe code & XSS patterns | Per language |
| 4 | GitHub Actions supply chain | `.github/workflows/` present |
| 5 | Docker security | `Dockerfile` present |
| 6 | Shell script security | `.sh` files present |
| 7 | CORS configuration | Web server code present |
| 8 | Auth & rate limiting | API server code present |
| 9 | Insecure HTTP URLs | Always |
| 10 | Prompt injection patterns | AI/agent code present |
| 11 | Security automation (Dependabot) | Always |

**Findings contract** (see "Finding Dispositions and Evidence"): every candidate ends `confirmed`, `needs_validation`, or `rejected`; only `confirmed` records carry vulnerability severity; checklist gaps are hardening notes; each `confirmed` record gets a fresh-context refutation pass (`tools/code-review/security-analysis.md` "Independent Verification"). Scanner output alone is never a completed audit.

<!-- AI-CONTEXT-END -->

## 1. Clone & Detect Stack

```bash
AUDIT_DIR="$HOME/.aidevops/.agent-workspace/tmp/security-audit"
mkdir -p "$AUDIT_DIR"
REPO_NAME=$(basename "$REPO_URL" .git)
CLONE_DIR="$AUDIT_DIR/$REPO_NAME"
rm -rf "$CLONE_DIR"
git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
cd "$CLONE_DIR"
ls Cargo.toml package.json requirements.txt go.mod Dockerfile .github/workflows/ 2>/dev/null
fd -e sh -e rs -e js -e ts -e py -e go --max-depth 3 2>/dev/null | head -5
```

## 2. Scan Categories

### 2.1 Secrets & Hardcoded Credentials (Always)

```bash
npx secretlint "**/*" --secretlintrc '{"rules":[{"id":"@secretlint/secretlint-rule-preset-recommend"}]}' 2>/dev/null || true
rg -in '(api[_-]?key|api[_-]?secret|access[_-]?token|auth[_-]?token|secret[_-]?key|private[_-]?key|password\s*=|passwd\s*=|credentials)' \
  --glob '!{*.lock,*.sum,node_modules/**,vendor/**,target/**,.git/**}' -l
rg -in 'AKIA[0-9A-Z]{16}' --glob '!{*.lock,*.sum,.git/**}'
rg -l '-----BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----' --glob '!{*.lock,.git/**}'
rg -in '(mongodb|postgres|mysql|redis)://[^"'\''[:space:]]+' --glob '!{*.lock,.git/**}'
rg -in '(token|secret|password|key)\s*[:=]\s*["\x27][A-Za-z0-9+/=]{20,}["\x27]' \
  --glob '!{*.lock,*.sum,node_modules/**,.git/**}'
```

### 2.2 Dependency Vulnerabilities (Lockfile present)

Cargo: `cargo audit` | npm: `npm audit --json` | pip: `pip audit -r requirements.txt` | Go: `govulncheck ./...` | Any: `osv-scanner --lockfile=<path>`

### 2.3 Unsafe Code & XSS Patterns (Per language)

**Rust:** `rg -n 'unsafe\s*\{|Command::new|\.unwrap\(\)' --glob '*.rs'`

**JS/TS (includes XSS):** `rg -n '\beval\s*\(|new Function\s*\(|child_process|exec\s*\(|innerHTML\s*=|dangerouslySetInnerHTML|v-html|document\.write\s*\(|\[innerHtml\]' --glob '*.{js,ts,jsx,tsx,vue,html}'`

**Python:** `rg -n '\beval\s*\(|\bexec\s*\(|subprocess\.|os\.system|pickle\.loads?|__import__' --glob '*.py'`

**Go:** `rg -n 'exec\.Command|os/exec|template\.HTML' --glob '*.go'`

### 2.4 GitHub Actions Supply Chain (`.github/workflows/` present)

```bash
rg -n 'uses:\s+[^#]+@(v\d|main|master|latest)' --glob '*.{yml,yaml}' -g '.github/**'  # Unpinned (hardening)
rg -L '^permissions:' --glob '*.{yml,yaml}' -g '.github/**'                             # Missing permissions (hardening)
rg -n 'echo.*\$\{\{\s*secrets\.' --glob '*.{yml,yaml}' -g '.github/**'                 # Leaked secrets (candidate)
rg -on 'uses:\s+([^/]+/[^@]+)@' --glob '*.{yml,yaml}' -g '.github/**' -r '$1' | \
  grep -v -E '^[^:]+:(actions|github)/' | sort -u                                       # Third-party actions
```

### 2.5 Docker Security (`Dockerfile` present)

```bash
rg -n '^USER |^FROM |^COPY --chown' Dockerfile* docker/Dockerfile* 2>/dev/null
rg -in '(ARG|ENV).*(password|secret|key|token)' Dockerfile* 2>/dev/null
rg -c '^FROM ' Dockerfile* 2>/dev/null  # >1 = multi-stage
ls .dockerignore 2>/dev/null
```

### 2.6 Shell Script Security (`.sh` files present)

```bash
fd -e sh --max-depth 5 -x shellcheck {} 2>/dev/null | head -50
rg -n 'eval\s|curl.*\|\s*(bash|sh)' --glob '*.sh'
```

### 2.7 CORS (Web server code present)

```bash
rg -in 'cors|access-control-allow-origin|origin.*\*|Access-Control-Allow-Credentials.*true' \
  --glob '*.{js,ts,py,go,rs,rb,java}'
```

### 2.8 Auth & Rate Limiting (API server present)

```bash
rg -in '(auth|authenticate|authorize|middleware|guard)' --glob '*.{js,ts,py,go,rs}' -l | head -10
rg -in '(rate.?limit|throttle|limiter|jwt|jsonwebtoken|session|cookie.*secure|httponly|samesite)' \
  --glob '*.{js,ts,py,go,rs}' -l
```

### 2.9 Insecure HTTP URLs (Always)

```bash
rg -n 'http://' \
  --glob '!{*.lock,*.sum,node_modules/**,vendor/**,target/**,.git/**,*.md,LICENSE*}' \
  --glob '*.{js,ts,py,go,rs,rb,java,yaml,yml,toml,json,sh}' | \
  grep -v 'localhost\|127\.0\.0\.1\|0\.0\.0\.0\|example\.com' | head -20
```

### 2.10 Prompt Injection (AI/agent code present)

```bash
rg -in '(prompt.?inject|prompt.?guard|content.?scan|injection.?detect)' \
  --glob '*.{js,ts,py,go,rs,sh,yaml,yml}' -l
rg -in '(openai|anthropic|langchain|llama|ollama|ai\.run|completion)' \
  --glob '*.{js,ts,py,go,rs,sh}' -l | head -10
```

For aidevops projects, verify `prompt-guard-helper.sh` integration. See `tools/security/prompt-injection-defender.md`.

### 2.11 Security Automation (Always)

```bash
ls .github/dependabot.yml renovate.json .renovaterc 2>/dev/null
rg -l '(codeql|snyk|trivy|grype|osv-scanner|semgrep)' --glob '*.{yml,yaml}' -g '.github/**' 2>/dev/null
ls SECURITY.md .github/SECURITY.md 2>/dev/null
```

## 3. Security Architecture Assessment

Review: auth model (API keys/OAuth/JWT/session), authorization (RBAC/ABAC), input validation, error handling (no internal detail leakage), logging (no sensitive data), encryption (TLS enforced, data at rest).

## 4. Finding Dispositions and Evidence

Scan matches in section 2 are **candidates**, not findings. Investigate each with the source-to-sink trace in `tools/code-review/security-analysis.md`, then record exactly one disposition. This applies the `reference/review-core.md` finding contract: a security finding describes a concrete, actionable exposure, not speculative hardening.

| Disposition | Meaning | Counts toward |
|-------------|---------|---------------|
| `confirmed` | The evidence chain is complete and the independent refutation pass failed to disprove it | Vulnerability severity and overall rating |
| `needs_validation` | Source-grounded lead missing **one named fact** (e.g., "is `/admin` reachable without the auth middleware in production config?") | Reported as unresolved; never severity |
| `rejected` | Disproved by a control visible in the source, unreachable, or test-only. Record the reason in one line | Nothing; keep for traceability |

Speculative ideas that cannot name the missing fact are dropped, not reported as `needs_validation`.

**Evidence chain** (required for `confirmed`; record the known fields for `needs_validation`):

- **Source ref**: commit SHA reviewed (and dirty state if not a clean clone)
- **Principal**: the lower-trust actor (anonymous user, tenant, PR author, dependency)
- **Entrypoint**: where that actor's input enters (`file:line`, route, workflow trigger)
- **Propagation**: the path from entrypoint to sink, with `file:line` hops
- **Sink / boundary**: what is crossed (shell, SQL, HTML, filesystem, secret, other tenant's data)
- **Controls**: source-visible validation, auth or sandboxing on the path, and why they do not prevent it
- **Impact**: the affected resource and the realistic result; mark it static-only, because target code is never executed (`tools/security/security-audit.md` rule 2)
- **Remediation**: the narrowest effective fix at the owning boundary

**Vulnerability severity** (`confirmed` only; based on demonstrated impact and realistic preconditions, not on pattern category):

| Severity | Criteria |
|----------|----------|
| **CRITICAL** | Unauthenticated or low-precondition RCE, live credential exposure, auth bypass on sensitive data |
| **HIGH** | Exploitable injection or privilege escalation that needs a plausible precondition (an account, a crafted PR on a `pull_request_target` workflow) |
| **MEDIUM** | Exploitable but limited in impact or reach (information disclosure, a DoS needing auth) |
| **LOW** | Exploitable only with unlikely preconditions or negligible impact |

**Hardening notes** (checklist gaps with no demonstrated exploit path; they never receive vulnerability severity). Prioritize them separately:

| Priority | Examples |
|----------|----------|
| **High** | Unpinned third-party GitHub Actions, missing workflow `permissions:`, Docker image runs as root (no `USER`), no rate limiting on auth endpoints |
| **Medium** | No Dependabot/Renovate, wildcard CORS without credentials, `http://` URLs in production config, excessive `.unwrap()` |
| **Low** | No `SECURITY.md`, single-stage Docker build, minor ShellCheck warnings |

A hardening gap becomes a vulnerability only when a candidate is traced through it to a `confirmed` exploit path; for example, an unpinned action is a vulnerability only if the action can be compromised and receives secrets or write tokens.

**Stage outcomes**: report each stage separately. Never infer one from another:

- **Scanners**: which ran, which were unavailable, which failed
- **Investigation**: candidates traced vs. not reached (and why)
- **Verification**: `confirmed` records that passed the independent refutation pass, or `self-review` if none was available
- **Blockers**: anything that leaves the audit partial (missing tool, budget, unreachable config)

Methodology note: dispositions, impact-based severity, fresh-context verification and separate stage reporting are adapted from Cloudflare's [security-audit-skill](https://github.com/cloudflare/security-audit-skill) (MIT). No text or code is copied.

## 5. Cleanup

```bash
rm -rf "$CLONE_DIR"
```

## Report Template

````markdown
## Security Audit Report: {repo-name}

**Repository:** {url}  **Source ref:** {commit SHA}  **Audit Date:** {ISO date}  **Languages:** {detected}
**Overall Assessment:** {Excellent | Strong | Good | Needs Work | Critical Issues}
**Audit completeness:** {complete | partial: blockers below}

### Confirmed Vulnerabilities

| Severity | Finding | Location | Principal → Sink | Verification |
|----------|---------|----------|------------------|--------------|
| HIGH | {description} | {file:line} | {principal} → {sink} | {fresh-context advisory \| self-review} |

{Per finding: the evidence chain fields and remediation.}

### Needs Validation

| Lead | Location | Missing fact |
|------|----------|--------------|
| {description} | {file:line} | {the one fact that would confirm or reject it} |

### Rejected Candidates

| Candidate | Location | Reason |
|-----------|----------|--------|
| {scan match} | {file:line} | {control, unreachable, or test-only} |

### Hardening Notes

| Priority | Note | Location | Category |
|----------|------|----------|----------|
| High | {checklist gap} | {file or config} | {category} |

### Stage Outcomes

- Scanners: {ran / unavailable / failed}
- Investigation: {candidates traced / not reached}
- Verification: {independent / self-review}
- Blockers: {none | list}

### Category Results

Report PASS/FAIL/WARN/SKIP for each category from the audit categories table above. Category status shows what was checked, not exhaustive coverage.

### Recommendations

1. **{Severity or hardening priority}**: {actionable recommendation}
````

## Overall Assessment

Vulnerability counts use `confirmed` records only. Hardening notes can lower a rating from Excellent to Good but can never produce Needs Work or Critical Issues.

| Rating | Criteria |
|--------|----------|
| **Excellent** | 0 confirmed vulnerabilities above LOW, at most 2 High hardening notes, comprehensive security automation |
| **Strong** | 0 confirmed above LOW, 3+ High hardening notes or limited security automation |
| **Good** | 0 confirmed CRITICAL/HIGH, and 1+ confirmed MEDIUM or 6+ High hardening notes |
| **Needs Work** | 0 confirmed CRITICAL, 1-2 confirmed HIGH, or 3+ confirmed MEDIUM |
| **Critical Issues** | Any confirmed CRITICAL, or 3+ confirmed HIGH |

If the audit is partial, say so next to the rating; do not rate unaudited scope as clean.
