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

### Results log

Scan results are appended to `.agents/SKILL-SCAN-RESULTS.md` automatically by
`security-helper.sh skill-scan` (batch) and `add-skill-helper.sh` (per-import).
The file contains the latest full scan summary and a history table for audit trail.

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

## VirusTotal Integration

VirusTotal provides an advisory second layer of security scanning alongside the
Cisco Skill Scanner. It checks file hashes against 70+ AV engines and scans
domains/URLs referenced in skill content.

**Key design**: VT scans are **advisory only** -- the Cisco Skill Scanner remains
the security gate for imports. VT adds value by detecting known malware hashes
and flagging malicious domains that static analysis cannot catch.

### How it works

1. **File hash lookup**: SHA256 of each skill file is checked against VT's database
2. **Domain reputation**: URLs extracted from skill content are checked for threats
3. **Rate limiting**: 16s between requests (free tier: 4 req/min, 500 req/day)
4. **Max 8 requests per skill scan** to avoid exhausting daily quota

### Usage

```bash
# Standalone VT scan
virustotal-helper.sh scan-skill /path/to/skill/
virustotal-helper.sh scan-file /path/to/file.md
virustotal-helper.sh scan-domain example.com
virustotal-helper.sh scan-url https://example.com/payload
virustotal-helper.sh status

# Via security-helper
security-helper.sh vt-scan skill /path/to/skill/
security-helper.sh vt-scan file /path/to/file.md
security-helper.sh vt-scan status

# Automatic: VT runs as advisory after Cisco scanner in:
# - security-helper.sh skill-scan all
# - add-skill-helper.sh (GitHub and ClawdHub imports)
```

### API key setup

```bash
# Recommended: gopass encrypted storage
aidevops secret set VIRUSTOTAL_MARCUSQUINN

# Alternative: credentials.sh
echo 'export VIRUSTOTAL_API_KEY="your_key"' >> ~/.config/aidevops/credentials.sh
```

## Environment Variables

```bash
# LLM analyzer (optional)
export SKILL_SCANNER_LLM_API_KEY="your_api_key"
export SKILL_SCANNER_LLM_MODEL="claude-3-5-sonnet-20241022"

# VirusTotal (optional - prefer gopass: aidevops secret set VIRUSTOTAL_MARCUSQUINN)
export VIRUSTOTAL_API_KEY="your_key"

# Cisco AI Defense (optional)
export AI_DEFENSE_API_KEY="your_key"
```

Store keys in `~/.config/aidevops/credentials.sh` (600 permissions).

## Response Guidelines

| Severity | Action |
|----------|--------|
| CRITICAL | Do not import. Remove if already imported. |
| HIGH | Block import. Review before allowing with `--force`. |
| MEDIUM | Warn. Review findings and plan fixes. |
| LOW | Informational. Address in future. |

<!-- AI-CONTEXT-END -->
