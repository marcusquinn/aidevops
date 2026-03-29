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
- **Install**: `uv tool install cisco-ai-skill-scanner` (auto-installed by `setup.sh`)
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
| VirusTotal | Free tier | ~16s/req | `VIRUSTOTAL_MARCUSQUINN` or `VIRUSTOTAL_API_KEY` (gopass) |
| Cisco AI Defense | Enterprise | ~1s | `AI_DEFENSE_API_KEY` |

## aidevops Integration

- **Import-time** (automatic): `add-skill-helper.sh` scans on import; CRITICAL/HIGH blocks unless `--force`
- **Batch**: `aidevops skill scan` / `security-helper.sh skill-scan all`
- **Setup-time**: `setup.sh` scans all skills on `aidevops update` (non-blocking)
- **Update-time**: `skill-update-helper.sh update` re-imports via `add-skill-helper.sh --force`
- **Results log**: `.agents/configs/configs/SKILL-SCAN-RESULTS.md` (latest summary + audit history)

## CLI Usage

```bash
skill-scanner scan /path/to/skill                                          # static only (fast)
skill-scanner scan /path/to/skill --use-behavioral                        # + AST dataflow
skill-scanner scan /path/to/skill --use-behavioral --use-llm              # full scan
skill-scanner scan /path/to/skill --use-llm --enable-meta                 # + FP filtering
skill-scanner scan-all /path/to/skills --recursive                        # batch
skill-scanner scan-all ./skills --fail-on-findings --format sarif --output results.sarif  # CI/CD
skill-scanner scan /path/to/skill --custom-rules /path/to/rules/          # custom YARA
skill-scanner scan /path/to/skill --disable-rule YARA_script_injection    # suppress rule
skill-scanner scan /path/to/skill --yara-mode permissive                  # fewer findings
```

## VirusTotal Integration

Advisory second layer alongside Cisco scanner. Checks file hashes (SHA256) against 70+ AV engines and scans domains/URLs in skill content. **VT is advisory only** — Cisco scanner remains the import gate.

- Rate limit: 16s between requests (free tier: 4 req/min, 500 req/day); max 8 requests per skill scan

```bash
virustotal-helper.sh scan-skill /path/to/skill/
virustotal-helper.sh scan-file /path/to/file.md
virustotal-helper.sh scan-domain example.com
virustotal-helper.sh scan-url https://example.com/payload
virustotal-helper.sh status

security-helper.sh vt-scan skill /path/to/skill/   # via security-helper
security-helper.sh vt-scan file /path/to/file.md
security-helper.sh vt-scan status
# Runs automatically (advisory) after Cisco scanner in: security-helper.sh skill-scan all, add-skill-helper.sh
```

**API key**: `aidevops secret set VIRUSTOTAL_MARCUSQUINN` (gopass preferred) or add to `~/.config/aidevops/credentials.sh`.

## Environment Variables

```bash
export SKILL_SCANNER_LLM_API_KEY="your_api_key"   # LLM analyzer (optional)
export SKILL_SCANNER_LLM_MODEL="claude-sonnet-4-6"
export VIRUSTOTAL_API_KEY="your_key"               # prefer gopass: aidevops secret set VIRUSTOTAL_MARCUSQUINN
export AI_DEFENSE_API_KEY="your_key"               # Cisco AI Defense (optional)
```

Store in `~/.config/aidevops/credentials.sh` (600 permissions).

## Response Guidelines

| Severity | Action |
|----------|--------|
| CRITICAL | Do not import. Remove if already imported. |
| HIGH | Block import. Review before allowing with `--force`. |
| MEDIUM | Warn. Review findings and plan fixes. |
| LOW | Informational. Address in future. |

<!-- AI-CONTEXT-END -->
