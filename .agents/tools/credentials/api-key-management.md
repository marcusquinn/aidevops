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

- **Primary**: Environment variables (`export CODACY_API_TOKEN="..."`)
- **Local storage**: `configs/*-config.json` (gitignored), `~/.config/coderabbit/api_key`
- **CI/CD**: GitHub Secrets (`SONAR_TOKEN`, `CODACY_API_TOKEN`, `GITHUB_TOKEN`)
- **Helper**: `.agents/scripts/setup-local-api-keys.sh` (set, load, list)
- **Token sources**: Codacy (app.codacy.com/account/api-tokens), SonarCloud (sonarcloud.io/account/security)
- **Security**: 600 permissions, never commit, rotate every 90 days
- **If compromised**: Revoke → regenerate → update local + GitHub secrets → verify
- **Test**: `echo "${CODACY_API_TOKEN:0:10}..."` to verify without exposing

<!-- AI-CONTEXT-END -->

## Storage Locations

### Environment Variables (Primary)

```bash
# Current session
export CODACY_API_TOKEN="YOUR_CODACY_API_TOKEN_HERE"
export SONAR_TOKEN="YOUR_SONAR_TOKEN_HERE"

# Persist in shell profile
echo 'export CODACY_API_TOKEN="YOUR_CODACY_API_TOKEN_HERE"' >> ~/.bashrc
echo 'export SONAR_TOKEN="YOUR_SONAR_TOKEN_HERE"' >> ~/.bashrc
```

### Local Configuration Files (Gitignored)

```text
configs/codacy-config.json           # Codacy API configuration
configs/sonar-config.json            # SonarCloud configuration
~/.config/coderabbit/api_key         # CodeRabbit CLI token
~/.codacy/config                     # Codacy CLI configuration
```

### GitHub Repository Secrets

```text
SONAR_TOKEN                          # SonarCloud analysis
CODACY_API_TOKEN                     # Codacy analysis
GITHUB_TOKEN                         # Automatic (provided by GitHub)
```

## Setup

### 1. Get SonarCloud Token

1. Go to https://sonarcloud.io/account/security
2. Generate token with project analysis permissions

### 2. Add GitHub Secrets

1. Go to https://github.com/marcusquinn/aidevops/settings/secrets/actions
2. Add `SONAR_TOKEN` and `CODACY_API_TOKEN`

### 3. Set Local API Keys

```bash
# Store securely (recommended)
bash .agents/scripts/setup-local-api-keys.sh set codacy YOUR_CODACY_API_TOKEN
bash .agents/scripts/setup-local-api-keys.sh set sonar YOUR_SONAR_TOKEN

# Load into environment
bash .agents/scripts/setup-local-api-keys.sh load

# List configured services
bash .agents/scripts/setup-local-api-keys.sh list
```

### 4. Test Configuration

```bash
# Test Codacy CLI
cd git/aidevops
bash .agents/scripts/codacy-cli.sh analyze

# Verify tokens loaded (partial display)
echo "Codacy token: ${CODACY_API_TOKEN:0:10}..."
echo "Sonar token: ${SONAR_TOKEN:0:10}..."
```

## Security Audit Checklist

- [ ] API keys in environment variables (not hardcoded)
- [ ] Local config files are gitignored
- [ ] GitHub Secrets configured for CI/CD
- [ ] No API keys in commit messages or code
- [ ] Minimal required permissions per token
- [ ] Regular token rotation (every 90 days)
- [ ] Revoke old tokens immediately after replacement
- [ ] Monitor token usage and access logs
- [ ] Document token sources and regeneration procedures
- [ ] Secure backup of configuration templates
- [ ] Emergency token revocation procedures documented
- [ ] Team access management for shared tokens

## Emergency: Compromised Key

1. **Revoke** the compromised key at provider immediately
2. **Generate** new API key
3. **Update** local environment variables and GitHub repository secrets
4. **Verify** all systems working with new key
5. **Document** incident and lessons learned
