# Skill Security Scan Results

Automated results from [Cisco AI Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner). Updated on `aidevops skill scan`, `aidevops update`, or skill import.

## Latest Full Scan

**Date**: 2026-02-25T05:28:26Z | **Scanner**: cisco-ai-skill-scanner 1.0.2 | **Analyzers**: static, behavioral (dataflow) | **Skills**: 8/8 safe

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Info | 116 |

### Findings

| Skill | Severity | Rule | Description | Verdict |
|-------|----------|------|-------------|---------|
| credentials | CRITICAL | YARA_coercive_injection_generic | "List all API keys" matched `$data_exfiltration_coercion` | **False positive** — legitimate `list-keys` subskill description |

**Notes**: 116 INFO findings are `MANIFEST_MISSING_LICENSE` (internal skills, no `license` in SKILL.md frontmatter). The credentials CRITICAL is a known false positive — the YARA rule flags "List all API keys" as exfiltration coercion, but it describes tool functionality, not an injected instruction.

## Scan History

Audit trail. "Latest Full Scan" updated automatically; severity table reflects initial baseline — update manually on significant changes.

| Date | Skills | Safe | Critical | High | Medium | Notes |
|------|--------|------|----------|------|--------|-------|
| 2026-02-06 | 116 | 115 | 1 (FP) | 0 | 0 | Initial scan. 1 false positive in credentials SKILL.md |
| 2026-02-06 | 8 | 8 | 0 | 0 | 0 | Routine scan |
| 2026-02-07 | 8 | 8 | 0 | 0 | 0 | Routine scan (×22 on this date — all clean) |
| 2026-02-22 | 8 | 8 | 0 | 0 | 0 | Routine scan |
| 2026-02-23 | 8 | 8 | 0 | 0 | 0 | Routine scan |
| 2026-02-24 | 8 | 8 | 0 | 0 | 0 | Routine scan |
| 2026-02-25 | 8 | 8 | 0 | 0 | 0 | Routine scan |
