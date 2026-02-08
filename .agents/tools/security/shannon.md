---
description: Shannon AI pentester - autonomous exploit-driven web application security testing
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Shannon AI Pentester

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Autonomous AI penetration tester (white-box, exploit-driven)
- **Repo**: [github.com/KeygraphHQ/shannon](https://github.com/KeygraphHQ/shannon)
- **License**: AGPL-3.0 (Lite), Commercial (Pro)
- **Helper**: `.agents/scripts/shannon-helper.sh`
- **Commands**: `install` | `start` | `logs` | `query` | `stop` | `status` | `help`
- **Runtime**: Docker (Temporal orchestration)
- **Benchmark**: 96.15% success rate on hint-free, source-aware XBOW Benchmark
- **Cost**: ~$50 USD per full run (Claude 4.5 Sonnet), 1-1.5 hours
- **Editions**: Shannon Lite (open source), Shannon Pro (enterprise)

**Vulnerability Coverage** (Lite):

| Category | Description |
|----------|-------------|
| Injection | SQL injection, command injection, NoSQL injection |
| XSS | Reflected, stored, DOM-based cross-site scripting |
| SSRF | Server-side request forgery, internal network access |
| Auth Bypass | Broken authentication, authorization flaws, IDOR, privilege escalation |

**Key Differentiator**: Shannon delivers actual exploits with reproducible PoCs, not just alerts. It follows a "No Exploit, No Report" policy to eliminate false positives.

<!-- AI-CONTEXT-END -->

## Overview

Shannon is a fully autonomous AI pentester that emulates a human penetration tester's methodology. It combines white-box source code analysis with black-box dynamic exploitation to find and prove real vulnerabilities in web applications.

Unlike traditional scanners that produce alert lists, Shannon:

1. Analyzes source code to identify attack vectors
2. Executes real exploits via browser automation and CLI tools
3. Reports only proven, exploitable vulnerabilities with copy-paste PoCs

## Architecture

Shannon uses a multi-agent architecture with four phases:

```text
Reconnaissance → Vulnerability Analysis → Exploitation → Reporting
                 (parallel per category)   (parallel per category)
```

### Phase 1: Reconnaissance

Builds a comprehensive attack surface map using source code analysis, Nmap, Subfinder, WhatWeb, and browser automation.

### Phase 2: Vulnerability Analysis (Parallel)

Specialized agents per OWASP category analyze code for potential flaws. Uses data flow analysis tracing user input to dangerous sinks.

### Phase 3: Exploitation (Parallel)

Dedicated exploit agents attempt real-world attacks using browser automation, CLI tools, and custom scripts. Only validated exploits proceed.

### Phase 4: Reporting

Compiles validated findings into a professional report with reproducible PoCs.

## Prerequisites

- **Docker** - Container runtime ([Install Docker](https://docs.docker.com/get-docker/))
- **AI Provider** (choose one):
  - Anthropic API key (recommended)
  - Claude Code OAuth token
  - [EXPERIMENTAL] OpenAI/Gemini via Router Mode

## Installation

```bash
# Install via helper script
./.agents/scripts/shannon-helper.sh install

# Or manually
git clone https://github.com/KeygraphHQ/shannon.git ~/.local/share/shannon
```

## Quick Start

```bash
# Check installation and Docker status
./.agents/scripts/shannon-helper.sh status

# Run a pentest against a target
./.agents/scripts/shannon-helper.sh start https://your-app.com /path/to/repo

# With a config file for authenticated testing
./.agents/scripts/shannon-helper.sh start https://your-app.com /path/to/repo ./configs/my-config.yaml

# Monitor progress
./.agents/scripts/shannon-helper.sh logs

# Query a specific workflow
./.agents/scripts/shannon-helper.sh query shannon-1234567890

# Stop all containers
./.agents/scripts/shannon-helper.sh stop
```

## Configuration

Shannon supports optional YAML configuration for authenticated testing and scope control.

### Authentication Config

```yaml
authentication:
  login_type: form
  login_url: "https://your-app.com/login"
  credentials:
    username: "test@example.com"
    password: "yourpassword"
    totp_secret: "LB2E2RX7XFHSTGCK"  # Optional for 2FA

  login_flow:
    - "Type $username into the email field"
    - "Type $password into the password field"
    - "Click the 'Sign In' button"

  success_condition:
    type: url_contains
    value: "/dashboard"
```

### Scope Rules

```yaml
rules:
  avoid:
    - description: "Skip logout functionality"
      type: path
      url_path: "/logout"

  focus:
    - description: "Emphasize API endpoints"
      type: path
      url_path: "/api"
```

## API Key Setup

```bash
# Recommended: gopass encrypted storage
aidevops secret set ANTHROPIC_API_KEY

# Alternative: credentials.sh (600 permissions)
# Add to ~/.config/aidevops/credentials.sh:
# export ANTHROPIC_API_KEY="your-key"
```

## Testing Local Applications

Docker containers cannot reach `localhost` on the host. Use `host.docker.internal`:

```bash
./.agents/scripts/shannon-helper.sh start http://host.docker.internal:3000 /path/to/repo
```

## Output Structure

Results are saved to `./audit-logs/{hostname}_{sessionId}/`:

```text
audit-logs/{hostname}_{sessionId}/
├── session.json          # Metrics and session data
├── agents/               # Per-agent execution logs
├── prompts/              # Prompt snapshots for reproducibility
└── deliverables/
    └── comprehensive_security_assessment_report.md
```

## Integration with AI DevOps Framework

### Security Pipeline

Shannon complements the existing security tooling:

| Tool | Focus | When to Use |
|------|-------|-------------|
| **Shannon** | Exploit-driven pentesting | Pre-release, periodic security audits |
| **Security Analysis** | AI-powered code review | Every commit/PR (fast) |
| **Snyk** | Dependency vulnerabilities | Every build (SCA/SAST) |
| **Ferret** | AI CLI config scanning | After config changes |
| **OSV-Scanner** | Known CVE detection | Dependency updates |
| **VirusTotal** | File/URL reputation | Skill imports |

### Recommended Workflow

1. **Every commit**: `security-helper.sh analyze` (fast, code-level)
2. **Every PR**: `snyk-helper.sh full` + `security-helper.sh analyze branch`
3. **Pre-release**: `shannon-helper.sh start` (full pentest)
4. **Periodic**: Weekly Shannon runs on staging environments

## Editions Comparison

| Feature | Shannon Lite | Shannon Pro |
|---------|-------------|-------------|
| Autonomous pentesting | Yes | Yes |
| Browser-based exploitation | Yes | Yes |
| Injection, XSS, SSRF, Auth | Yes | Yes |
| LLM-powered data flow analysis | No | Yes |
| Deep static analysis | No | Yes |
| CI/CD integration | Basic | Advanced |
| License | AGPL-3.0 | Commercial |

## Disclaimers

- **Staging/dev only**: Shannon actively exploits targets. Never run on production.
- **Authorization required**: You must have written authorization for the target system.
- **Human review**: LLM-generated reports require human validation.
- **Cost awareness**: ~$50 USD per full run with Claude 4.5 Sonnet.

## Troubleshooting

### Docker Not Running

```bash
# Check Docker status
docker info

# Start Docker Desktop (macOS)
open -a Docker
```

### Shannon Not Found

```bash
# Reinstall
./.agents/scripts/shannon-helper.sh install

# Verify installation
ls -la ~/.local/share/shannon/
```

### Temporal UI

Monitor workflow progress at `http://localhost:8233` when Shannon is running.

## Resources

- **GitHub**: [github.com/KeygraphHQ/shannon](https://github.com/KeygraphHQ/shannon)
- **Website**: [keygraph.io](https://keygraph.io)
- **Discord**: [discord.gg/KAqzSHHpRt](https://discord.gg/KAqzSHHpRt)
- **Sample Reports**: [Juice Shop](https://github.com/KeygraphHQ/shannon/blob/main/sample-reports/shannon-report-juice-shop.md), [c{api}tal](https://github.com/KeygraphHQ/shannon/blob/main/sample-reports/shannon-report-capital-api.md), [crAPI](https://github.com/KeygraphHQ/shannon/blob/main/sample-reports/shannon-report-crapi.md)
- **XBOW Benchmark**: [Benchmark Results](https://github.com/KeygraphHQ/shannon/tree/main/xben-benchmark-results/README.md)

---

**Shannon provides autonomous, exploit-driven penetration testing that proves vulnerabilities are real before reporting them, complementing the framework's existing static analysis and dependency scanning tools.**
