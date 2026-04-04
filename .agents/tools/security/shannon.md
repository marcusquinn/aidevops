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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shannon AI Pentester

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Autonomous AI penetration tester (white-box, exploit-driven)
- **Repo**: [github.com/KeygraphHQ/shannon](https://github.com/KeygraphHQ/shannon)
- **License**: AGPL-3.0 (Lite), Commercial (Pro)
- **Helper**: `.agents/scripts/shannon-helper.sh`
- **Commands**: `install` | `start` | `logs` | `query` | `stop` | `status` | `help`
- **Runtime**: Docker (Temporal orchestration, UI at `http://localhost:8233`)
- **Benchmark**: 96.15% success rate on hint-free, source-aware XBOW Benchmark
- **Cost**: ~$50 USD per full run (Claude 4.5 Sonnet), 1-1.5 hours
- **Editions**: Lite (open source, AGPL-3.0), Pro (enterprise, commercial)
- **Resources**: [Website](https://keygraph.io) | [Discord](https://discord.gg/KAqzSHHpRt) | [Sample Reports](https://github.com/KeygraphHQ/shannon/tree/main/sample-reports) | [XBOW Benchmark](https://github.com/KeygraphHQ/shannon/tree/main/xben-benchmark-results/README.md)

<!-- AI-CONTEXT-END -->

## Safety (read first)

- **Staging/dev only** — Shannon actively exploits targets. Never run on production.
- **Authorization required** — written authorization for the target system is mandatory.
- **Human review** — LLM-generated reports require human validation.
- **Cost awareness** — ~$50 USD per full run with Claude 4.5 Sonnet.

## Vulnerability Coverage (Lite)

| Category | Description |
|----------|-------------|
| Injection | SQL injection, command injection, NoSQL injection |
| XSS | Reflected, stored, DOM-based cross-site scripting |
| SSRF | Server-side request forgery, internal network access |
| Auth Bypass | Broken authentication, authorization flaws, IDOR, privilege escalation |

**Key differentiator**: Shannon delivers actual exploits with reproducible PoCs ("No Exploit, No Report" — zero false positives).

## Architecture

Four-phase multi-agent pipeline, with phases 2-3 parallelized per OWASP category:

```text
Reconnaissance → Vulnerability Analysis → Exploitation → Reporting
                 (parallel per category)   (parallel per category)
```

1. **Recon** — attack surface map via source code analysis, Nmap, Subfinder, WhatWeb, browser automation
2. **Analysis** — specialized agents per OWASP category; data flow analysis tracing user input to dangerous sinks
3. **Exploitation** — real-world attacks via browser automation, CLI tools, custom scripts; only validated exploits proceed
4. **Reporting** — professional report with reproducible PoCs

## Prerequisites

- **Docker** — container runtime ([Install Docker](https://docs.docker.com/get-docker/))
- **AI Provider** (one of): Anthropic API key (recommended), Claude Code OAuth token, [EXPERIMENTAL] OpenAI/Gemini via Router Mode

## Installation and API Key

```bash
# Install via helper
./.agents/scripts/shannon-helper.sh install

# Or manually
git clone https://github.com/KeygraphHQ/shannon.git ~/.local/share/shannon

# API key — gopass (recommended)
aidevops secret set ANTHROPIC_API_KEY

# Alternative: ~/.config/aidevops/credentials.sh (600 perms)
# export ANTHROPIC_API_KEY="your-key"
```

## Usage

```bash
# Check installation and Docker status
./.agents/scripts/shannon-helper.sh status

# Run a pentest
./.agents/scripts/shannon-helper.sh start https://your-app.com /path/to/repo

# With config for authenticated testing
./.agents/scripts/shannon-helper.sh start https://your-app.com /path/to/repo ./configs/my-config.yaml

# Monitor progress
./.agents/scripts/shannon-helper.sh logs

# Query a specific workflow
./.agents/scripts/shannon-helper.sh query shannon-1234567890

# Stop all containers
./.agents/scripts/shannon-helper.sh stop
```

**Local apps**: Docker cannot reach `localhost` — use `host.docker.internal`:

```bash
./.agents/scripts/shannon-helper.sh start http://host.docker.internal:3000 /path/to/repo
```

## Configuration

Optional YAML for authenticated testing and scope control.

### Authentication

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

## Output

Results saved to `./audit-logs/{hostname}_{sessionId}/`:

```text
audit-logs/{hostname}_{sessionId}/
├── session.json          # Metrics and session data
├── agents/               # Per-agent execution logs
├── prompts/              # Prompt snapshots for reproducibility
└── deliverables/
    └── comprehensive_security_assessment_report.md
```

## Framework Integration

Shannon complements existing security tooling in the recommended pipeline:

| Stage | Tool | Focus |
|-------|------|-------|
| Every commit | `security-helper.sh analyze` | AI-powered code review (fast) |
| Every PR | Snyk + `security-helper.sh analyze branch` | Dependency vulnerabilities + code |
| Pre-release | `shannon-helper.sh start` | Full exploit-driven pentest |
| Periodic | Weekly Shannon on staging | Ongoing security posture |

Other tools: Ferret (AI CLI config scanning), OSV-Scanner (known CVEs), VirusTotal (file/URL reputation).

## Editions

| Feature | Lite | Pro |
|---------|------|-----|
| Autonomous pentesting, browser exploitation | Yes | Yes |
| Injection, XSS, SSRF, Auth bypass | Yes | Yes |
| LLM-powered data flow + deep static analysis | No | Yes |
| CI/CD integration | Basic | Advanced |

## Troubleshooting

```bash
# Docker not running
docker info                    # Check status
open -a Docker                 # Start Docker Desktop (macOS)

# Shannon not found
./.agents/scripts/shannon-helper.sh install   # Reinstall
ls -la ~/.local/share/shannon/                # Verify
```
