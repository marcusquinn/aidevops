<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Skill Security Scan Results

Automated output from [Cisco AI Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner). Updated by `aidevops skill scan`, `aidevops update`, and skill import.

## Latest Full Scan

- **Date**: 2026-02-25T05:28:26Z
- **Scanner**: cisco-ai-skill-scanner 1.0.2
- **Analyzers**: static, behavioral (dataflow)
- **Skills**: 8/8 safe
- **Severity counts**: Critical 1, High 0, Medium 0, Low 0, Info 116

### Non-routine finding

| Skill | Rule | Description | Verdict |
|-------|------|-------------|---------|
| credentials | YARA_coercive_injection_generic | `"List all API keys"` matched `$data_exfiltration_coercion` | **False positive** — legitimate `list-keys` subskill description |

### Interpretation

- The only CRITICAL finding is the known credentials false positive above.
- All 116 INFO findings are `MANIFEST_MISSING_LICENSE` on internal skills that omit `license` in `SKILL.md` frontmatter.
- No HIGH, MEDIUM, or LOW findings were reported.

## Scan History

Audit trail. `Latest Full Scan` updates automatically; expand this table only when scan behavior changes or the baseline shifts.

| Date | Skills | Safe | Critical | High | Medium | Notes |
|------|--------|------|----------|------|--------|-------|
| 2026-02-06 | 116 | 115 | 1 (FP) | 0 | 0 | Initial scan; credentials SKILL false positive |
| 2026-02-06 | 8 | 8 | 0 | 0 | 0 | Routine scan |
| 2026-02-07 | 8 | 8 | 0 | 0 | 0 | Routine scan (22 runs; all clean) |
| 2026-02-22 | 8 | 8 | 0 | 0 | 0 | Routine scan |
| 2026-02-23 | 8 | 8 | 0 | 0 | 0 | Routine scan |
| 2026-02-24 | 8 | 8 | 0 | 0 | 0 | Routine scan |
| 2026-02-25 | 8 | 8 | 0 | 0 | 0 | Routine scan |
