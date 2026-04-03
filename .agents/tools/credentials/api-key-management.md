---
description: API key management and rotation guide
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# API Key Management Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Store**: `aidevops secret set NAME` (gopass, preferred) or `setup-local-api-keys.sh set NAME TOKEN` (plaintext fallback)
- **CI/CD**: GitHub Secrets (`SONAR_TOKEN`, `CODACY_API_TOKEN`, `GITHUB_TOKEN`)
- **Verify**: `setup-local-api-keys.sh list` (redacted) or `echo "${VAR:0:10}..."` (partial)
- **Rotate**: every 90 days, minimal-scope tokens, revoke old immediately
- **Compromised**: Revoke at provider → regenerate → update local + GitHub secrets → verify
- **Setup details**: `api-key-setup.md` | **Encrypted storage**: `gopass.md`

<!-- AI-CONTEXT-END -->

## Security Rules

1. **Never commit** API keys to git history
2. **Never accept** secret values in AI conversation — instruct user to run `aidevops secret set NAME`
3. **600 permissions** on all credential files, 700 on parent directories
4. **Minimal scope** — request only required permissions per token
5. **Monitor** token usage and access logs at provider dashboards
6. **Document** token sources and regeneration procedures

## Storage Hierarchy

| Tier | Location | Use |
|------|----------|-----|
| **Encrypted** (preferred) | gopass (`aidevops secret`) | All secrets — see `gopass.md` |
| **Plaintext fallback** | `~/.config/aidevops/credentials.sh` (600) | When gopass unavailable — see `api-key-setup.md` |
| **CI/CD** | GitHub Repository Secrets | `SONAR_TOKEN`, `CODACY_API_TOKEN`, `GITHUB_TOKEN` (auto) |
| **Local config** (gitignored) | `configs/*-config.json`, `~/.config/coderabbit/api_key` | Service-specific config |

## Emergency: Compromised Key

1. **Revoke** at provider immediately
2. **Regenerate** new key
3. **Update** local (`aidevops secret set NAME`) + GitHub Secrets
4. **Verify** all systems working
5. **Document** incident
