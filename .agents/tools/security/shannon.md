---
description: Shannon AI pentester - autonomous web application security testing
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Shannon AI Pentester

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `shannon-helper.sh [install|start|stop|status|query|logs|reports]`
- **Source**: [github.com/KeygraphHQ/shannon](https://github.com/KeygraphHQ/shannon)
- **License**: AGPL-3.0 (free for internal security testing)
- **Prerequisites**: Docker, Anthropic API key
- **Install location**: `~/.aidevops/tools/shannon/`
- **Reports**: `~/.aidevops/tools/shannon/audit-logs/`
- **Cost**: ~$50 USD per full pentest run
- **Duration**: 1-1.5 hours per run
- **XBOW Benchmark**: 96.15% success rate (hint-free, source-aware)

**CRITICAL**: NEVER run Shannon against production environments. Use staging,
development, or local environments only.

<!-- AI-CONTEXT-END -->

## What Shannon Does

Shannon is a fully autonomous AI pentester that finds and exploits real
vulnerabilities in web applications. Unlike scanners that report potential
issues, Shannon executes actual exploits to prove vulnerabilities are real.

### Vulnerability Coverage

| Category | What Shannon Tests |
|----------|--------------------|
| Injection | SQL injection, command injection, NoSQL injection |
| XSS | Reflected, stored, DOM-based cross-site scripting |
| SSRF | Server-side request forgery, internal network access |
| Auth/AuthZ | Authentication bypass, privilege escalation, IDOR |

### Architecture

Shannon uses a 4-phase multi-agent workflow:

1. **Reconnaissance** - Maps attack surface (code analysis + live exploration)
2. **Vulnerability Analysis** - Parallel agents hunt for flaws per OWASP category
3. **Exploitation** - Executes real attacks to prove vulnerabilities
4. **Reporting** - Generates pentest-grade report with reproducible PoCs

Runs on Docker with Temporal for workflow orchestration.

## Usage

### Installation

```bash
shannon-helper.sh install
```

This clones the Shannon repository to `~/.aidevops/tools/shannon/` and
configures the `.env` file with your Anthropic API key.

### Running a Pentest

```bash
# Basic pentest (white-box: needs source code access)
shannon-helper.sh start https://myapp.local:3000 /path/to/repo

# With authentication config
shannon-helper.sh start https://myapp.local:3000 /path/to/repo ./config.yaml
```

For local applications, use `host.docker.internal` instead of `localhost`:

```bash
shannon-helper.sh start http://host.docker.internal:3000 /path/to/repo
```

### Monitoring

```bash
shannon-helper.sh status              # Installation and container status
shannon-helper.sh logs                # Tail latest workflow log
shannon-helper.sh logs <workflow-id>  # Tail specific workflow
shannon-helper.sh query <workflow-id> # Query workflow progress
```

The Temporal Web UI is available at `http://localhost:8233` while Shannon
is running.

### Reports

```bash
shannon-helper.sh reports             # List all reports
shannon-helper.sh reports myapp.local # Filter by hostname
```

Reports are saved to `~/.aidevops/tools/shannon/audit-logs/{hostname}_{sessionId}/`
with the main report at `deliverables/comprehensive_security_assessment_report.md`.

### Cleanup

```bash
shannon-helper.sh stop          # Stop containers (preserves data)
shannon-helper.sh stop --clean  # Stop and remove all data/volumes
```

## Configuration

Create a YAML config file for authenticated testing:

```yaml
authentication:
  login_type: form
  login_url: "https://myapp.local/login"
  credentials:
    username: "test@example.com"
    password: "testpassword"
    totp_secret: "BASE32SECRET"  # Optional for 2FA

  login_flow:
    - "Type $username into the email field"
    - "Type $password into the password field"
    - "Click the 'Sign In' button"

  success_condition:
    type: url_contains
    value: "/dashboard"

rules:
  avoid:
    - description: "Skip logout endpoint"
      type: path
      url_path: "/logout"
  focus:
    - description: "Focus on API endpoints"
      type: path
      url_path: "/api"
```

## Integration with aidevops

Shannon complements the existing security tools in aidevops:

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `security-helper.sh` | Static analysis, dependency scanning | Every commit/PR |
| `secretlint` | Secret detection | Every commit |
| **Shannon** | Dynamic exploitation testing | Before releases, after major changes |
| `snyk` | Dependency vulnerabilities | CI/CD pipeline |

### Recommended Workflow

1. **Development**: `security-helper.sh analyze` on each PR
2. **Pre-release**: Run Shannon against staging environment
3. **Post-fix**: Re-run Shannon to verify fixes

## Limitations

- White-box only (requires source code access)
- Currently covers: Injection, XSS, SSRF, Auth/AuthZ
- Does not cover: dependency vulnerabilities, misconfigurations, DoS
- LLM-based: findings should be verified by a human
- Mutative: actively modifies target application data during testing
- Cost: ~$50 per run (Anthropic API usage)
