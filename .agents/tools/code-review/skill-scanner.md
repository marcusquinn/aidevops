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

## Quick Reference

- **Purpose**: Scan AI agent skills (`SKILL.md`, `AGENTS.md`, scripts) for import-blocking security risks
- **Source**: [cisco-ai-defense/skill-scanner](https://github.com/cisco-ai-defense/skill-scanner) (Apache 2.0)
- **Install**: `uv tool install cisco-ai-skill-scanner` (`setup.sh` auto-installs it)
- **No install**: `uvx cisco-ai-skill-scanner scan /path/to/skill`
- **Entry points**: `aidevops skill scan`, `security-helper.sh skill-scan`, `add-skill-helper.sh`
- **Formats**: `summary`, `json`, `markdown`, `table`, `sarif`
- **Exit codes**: `0` safe, `1` findings

## Threat Coverage

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

## Engines

| Engine | Cost | Speed | Requirements |
|--------|------|-------|-------------|
| Static (YAML + YARA) | Free | ~150ms | None |
| Behavioral (AST/dataflow) | Free | ~150ms | None |
| LLM-as-judge | API cost | ~2s | `SKILL_SCANNER_LLM_API_KEY` |
| Meta-analyzer (FP filter) | API cost | ~1s | `SKILL_SCANNER_LLM_API_KEY` |
| VirusTotal | Free tier | ~16s/request | `VIRUSTOTAL_MARCUSQUINN` or `VIRUSTOTAL_API_KEY` |
| Cisco AI Defense | Enterprise | ~1s | `AI_DEFENSE_API_KEY` |

Keys: `~/.config/aidevops/credentials.sh` (600 perms) or `aidevops secret set <KEY_NAME>`.

## aidevops Integration

- **Import gate**: `add-skill-helper.sh` — `CRITICAL`/`HIGH` blocks unless `--skip-security` (or explicit interactive override)
- **Batch scans**: `aidevops skill scan`, `security-helper.sh skill-scan all`
- **Update path**: `setup.sh` scans all skills during `aidevops update` (non-blocking); `skill-update-helper.sh update` re-imports with `--force`
- **Audit log**: `.agents/configs/SKILL-SCAN-RESULTS.md`
- **VirusTotal layer**: advisory scan for file hashes and embedded domains/URLs; never replaces the import gate. Limits: 4 req/min, 500/day, max 8 per skill scan.

## CLI

```bash
skill-scanner scan /path/to/skill                                    # static only
skill-scanner scan /path/to/skill --use-behavioral --use-llm         # full scan
skill-scanner scan-all /path/to/skills --recursive                   # batch scan
skill-scanner scan-all ./skills --fail-on-findings --format sarif    # CI/CD gate

virustotal-helper.sh scan-skill /path/to/skill/
virustotal-helper.sh scan-file /path/to/file.md
virustotal-helper.sh scan-domain example.com
security-helper.sh vt-scan skill /path/to/skill/                     # runs after Cisco scanner
```

Useful flags: `--enable-meta` (false-positive filter), `--custom-rules /path/`, `--disable-rule RULE_NAME`, `--yara-mode permissive`.

## Response Guidelines

| Severity | Action |
|----------|--------|
| CRITICAL | Do not import. Remove if already imported. |
| HIGH | Block import. Allow only with `--skip-security` + explicit interactive override. |
| MEDIUM | Warn. Review and plan fixes. |
| LOW | Informational. Address in future. |
