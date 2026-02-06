---
description: Cisco Skill Scanner for detecting threats in AI agent skills
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Cisco Skill Scanner - Agent Skill Security

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Security scanner for AI Agent Skills (SKILL.md, AGENTS.md, scripts)
- **Source**: [cisco-ai-defense/skill-scanner](https://github.com/cisco-ai-defense/skill-scanner) (Apache 2.0)
- **Install**: `uv pip install cisco-ai-skill-scanner` or `pip install cisco-ai-skill-scanner`
- **Run without install**: `uvx cisco-ai-skill-scanner scan /path/to/skill`
- **aidevops integration**: `aidevops skill scan` or `security-helper.sh skill-scan`
- **Formats**: summary, json, markdown, table, sarif
- **Exit codes**: 0=safe, 1=findings detected

## Threat Detection

| Category | AITech Code | Severity | Detection |
|----------|-------------|----------|-----------|
| Prompt injection | AITech-1.1/1.2 | HIGH-CRITICAL | YAML + YARA + LLM |
| Command injection | AITech-9.1.4 | CRITICAL | YAML + YARA + LLM |
| Data exfiltration | AITech-8.2 | CRITICAL | YAML + YARA + LLM |
| Hardcoded secrets | AITech-8.2 | CRITICAL | YAML + YARA + LLM |
| Tool/permission abuse | AITech-12.1 | MEDIUM-CRITICAL | Python + YARA |
| Obfuscation | - | MEDIUM-CRITICAL | YAML + YARA + binary |
| Capability inflation | AITech-4.3 | LOW-HIGH | YAML + YARA + Python |
| Indirect prompt injection | AITech-1.2 | HIGH | YARA + LLM |
| Autonomy abuse | AITech-13.1 | MEDIUM-HIGH | YAML + YARA + LLM |
| Tool chaining | AITech-8.2.3 | HIGH | YARA + LLM |

## Analysis Engines

| Engine | Cost | Speed | Requirements |
|--------|------|-------|-------------|
| Static (YAML + YARA) | Free | ~150ms | None |
| Behavioral (AST dataflow) | Free | ~150ms | None |
| LLM-as-judge | API cost | ~2s | `SKILL_SCANNER_LLM_API_KEY` |
| Meta-analyzer (FP filter) | API cost | ~1s | `SKILL_SCANNER_LLM_API_KEY` |
| VirusTotal | Free tier | ~1s | `VIRUSTOTAL_API_KEY` |
| Cisco AI Defense | Enterprise | ~1s | `AI_DEFENSE_API_KEY` |

## aidevops Integration Points

### Import-time scanning (automatic)

When `skill-scanner` is installed, `add-skill-helper.sh` automatically scans
skills during import. CRITICAL/HIGH findings block import unless `--force`.

### Batch scanning

```bash
# Scan all imported skills
aidevops skill scan

# Scan specific skill
aidevops skill scan cloudflare-platform

# Via security-helper directly
security-helper.sh skill-scan all
security-helper.sh skill-scan cloudflare-platform
```

### Setup-time scanning

`setup.sh` runs a security scan on all imported skills during `aidevops update`.
Non-blocking: findings are reported but don't halt setup.

### Update-time scanning

`skill-update-helper.sh update` re-imports via `add-skill-helper.sh --force`,
which triggers the security scan on the updated content.

## CLI Usage

```bash
# Static-only scan (fast, no API key)
skill-scanner scan /path/to/skill

# With behavioral analysis
skill-scanner scan /path/to/skill --use-behavioral

# Full scan with LLM
skill-scanner scan /path/to/skill --use-behavioral --use-llm

# With false-positive filtering
skill-scanner scan /path/to/skill --use-llm --enable-meta

# Batch scan
skill-scanner scan-all /path/to/skills --recursive

# CI/CD mode
skill-scanner scan-all ./skills --fail-on-findings --format sarif --output results.sarif

# Custom YARA rules
skill-scanner scan /path/to/skill --custom-rules /path/to/rules/

# Disable noisy rules
skill-scanner scan /path/to/skill --disable-rule YARA_script_injection

# Permissive mode (fewer findings)
skill-scanner scan /path/to/skill --yara-mode permissive
```

## Environment Variables

```bash
# LLM analyzer (optional)
export SKILL_SCANNER_LLM_API_KEY="your_api_key"
export SKILL_SCANNER_LLM_MODEL="claude-3-5-sonnet-20241022"

# VirusTotal (optional)
export VIRUSTOTAL_API_KEY="your_key"

# Cisco AI Defense (optional)
export AI_DEFENSE_API_KEY="your_key"
```

Store keys in `~/.config/aidevops/mcp-env.sh` (600 permissions).

## Response Guidelines

| Severity | Action |
|----------|--------|
| CRITICAL | Do not import. Remove if already imported. |
| HIGH | Block import. Review before allowing with `--force`. |
| MEDIUM | Warn. Review findings and plan fixes. |
| LOW | Informational. Address in future. |

<!-- AI-CONTEXT-END -->
