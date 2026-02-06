# Skill Security Scan Results

Automated scan results from [Cisco AI Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner).
Updated on each `aidevops skill scan`, `aidevops update`, or skill import.

## Latest Full Scan

**Date**: 2026-02-06T23:16:02Z
**Scanner**: cisco-ai-skill-scanner 1.0.2
**Analyzers**: static, behavioral (dataflow)
**Skills scanned**: 116
**Safe**: 115

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
| credentials | CRITICAL | YARA_coercive_injection_generic | "List all API keys" in tool description matched `$data_exfiltration_coercion` pattern | **False positive** -- legitimate description of the `list-keys` credential management subskill |

### Notes

- All 116 INFO findings are `MANIFEST_MISSING_LICENSE` (no `license` field in SKILL.md frontmatter). These are internal aidevops skills, not third-party imports.
- The credentials CRITICAL is a known false positive. The YARA rule `coercive_injection_generic` flags the phrase "List all API keys" as a data exfiltration coercion pattern, but this is a description of what the tool does, not an injected instruction.

## Scan History

| Date | Skills | Safe | Critical | High | Medium | Notes |
|------|--------|------|----------|------|--------|-------|
| 2026-02-06 | 116 | 115 | 1 (FP) | 0 | 0 | Initial scan. 1 false positive in credentials SKILL.md |
