---
description: GitHub Actions CI/CD workflow setup and management
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  list: true
  webfetch: true
permission:
  edit:
    ".github/workflows/*": allow
    "*": deny
  write:
    ".github/workflows/*": allow
    "*": deny
---

# GitHub Actions Setup Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Workflow File**: `.github/workflows/code-quality.yml`
- **Triggers**: Push to main/develop, PRs to main
- **Jobs**: Framework validation, SonarCloud analysis, Codacy analysis
- **Required Secrets**: `SONAR_TOKEN` (configured), `CODACY_API_TOKEN` (needs setup)
- **Auto-Provided**: `GITHUB_TOKEN` by GitHub
- **SonarCloud Dashboard**: https://sonarcloud.io/project/overview?id=marcusquinn_aidevops
- **Codacy Dashboard**: https://app.codacy.com/gh/marcusquinn/aidevops
- **Actions URL**: https://github.com/marcusquinn/aidevops/actions
- **Add Secrets**: Repository Settings → Secrets and variables → Actions
<!-- AI-CONTEXT-END -->

## Automated Code Quality Analysis

### Current GitHub Actions Status

#### ✅ Configured and Working:

- **SonarCloud Analysis**: ✅ Runs on every push and PR
- **Framework Validation**: ✅ Validates repository structure
- **Security Scanning**: ✅ Checks for hardcoded API keys

#### Requires Setup:

- **Codacy Analysis**: Requires `CODACY_API_TOKEN` secret

## Required GitHub Repository Secrets

### **1. SONAR_TOKEN (Already Configured)**

- **Status**: ✅ **CONFIGURED**
- **Purpose**: SonarCloud analysis in GitHub Actions
- **Value**: Your SonarCloud API token
- **Source**: https://sonarcloud.io/account/security

### **2. CODACY_API_TOKEN (Needs Setup)**

- **Status**: ❌ **NEEDS CONFIGURATION**
- **Purpose**: Codacy analysis in GitHub Actions
- **Value**: Your Codacy API token
- **Source**: https://app.codacy.com/account/api-tokens

## Setup Instructions

### **Add Missing GitHub Secret:**

1. **Go to Repository Settings**:

   ```text
   https://github.com/marcusquinn/aidevops/settings/secrets/actions
   ```

2. **Click "New repository secret"**

3. **Add Codacy Secret**:
   - **Name**: `CODACY_API_TOKEN`
   - **Value**: Your Codacy API token (get from secure local storage)

## Workflow Triggers

### **Automatic Execution:**

- **Push to main**: ✅ Triggers full analysis
- **Push to develop**: ✅ Triggers full analysis
- **Pull Request to main**: ✅ Triggers full analysis

### **Analysis Jobs:**

1. **Framework Validation**: Repository structure and security checks
2. **SonarCloud Analysis**: Code quality, security, and maintainability
3. **Codacy Analysis**: Code quality and complexity analysis

## Viewing Results

### **SonarCloud Dashboard:**

```text
https://sonarcloud.io/project/overview?id=marcusquinn_aidevops
```

### **Codacy Dashboard:**

```text
https://app.codacy.com/gh/marcusquinn/aidevops
```

### **GitHub Actions:**

```text
https://github.com/marcusquinn/aidevops/actions
```

## Workflow Configuration

### **File**: `.github/workflows/code-quality.yml`

#### **Key Features:**

- **Multi-job workflow** with framework validation and code analysis
- **Security scanning** to prevent API key exposure
- **Conditional Codacy analysis** (runs only if token is configured)
- **Comprehensive reporting** with links to analysis dashboards
- **Fail-fast security** checks to prevent credential exposure

#### **Environment Variables Used:**

- `GITHUB_TOKEN`: Automatic (provided by GitHub)
- `SONAR_TOKEN`: From repository secrets
- `CODACY_API_TOKEN`: From repository secrets (optional)

## Security Features

### **Automated Security Checks:**

- **API Key Detection**: Scans for hardcoded credentials
- **Repository Structure**: Validates framework integrity
- **Secret Management**: Uses GitHub Secrets for sensitive data

### **Security Best Practices:**

- **No secrets in code**: All API keys use GitHub Secrets
- **Conditional execution**: Graceful handling of missing secrets
- **Fail-fast security**: Stops workflow if security issues detected

## Next Steps

1. **Add CODACY_API_TOKEN** to GitHub repository secrets
2. **Push a commit** to trigger the workflow
3. **Verify analysis results** in SonarCloud and Codacy dashboards
4. **Monitor workflow runs** in GitHub Actions

## Benefits

- **Automated Quality Gates**: Every commit analyzed for quality
- **Security Monitoring**: Prevents credential exposure
- **Multi-Platform Analysis**: SonarCloud + Codacy coverage
- **Professional Standards**: Industry-grade CI/CD pipeline

**Your repository now has comprehensive automated code quality analysis running on every commit!**
