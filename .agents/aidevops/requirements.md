---
description: Framework requirements and capabilities
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Framework Requirements & Capabilities

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Services**: 25+ providers with unified command patterns
- **Quality**: SonarCloud A-grade, CodeFactor A-grade, ShellCheck zero violations
- **Security**: Zero credential exposure, encrypted storage, confirmation prompts
- **Performance**: <1s local ops, <5s API calls, 10+ concurrent operations
- **MCP**: Real-time data access via MCP servers
- **Quality check**: `curl -s "https://sonarcloud.io/api/measures/component?component=marcusquinn_aidevops&metricKeys=bugs,vulnerabilities,code_smells"`
- **ShellCheck**: `find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;`

<!-- AI-CONTEXT-END -->

## Core Requirements

### Functional

- **Multi-provider**: Manage 25+ services through unified interfaces
- **Secure credentials**: Enterprise-grade security for all credentials (see `security-requirements.md`)
- **Consistent commands**: Unified `[service]-helper.sh [command] [account] [target]` pattern
- **Real-time integration**: MCP server support for live data access
- **Guided setup**: AI-assisted configuration via `setup-wizard-helper.sh`
- **Health monitoring**: Status checks across all services
- **Automated ops**: Support for automated DevOps workflows
- **Error recovery**: Robust error handling with retry and backoff

### Non-Functional

| Requirement | Target |
|-------------|--------|
| Security | Zero credential exposure, secure by default |
| Reliability | 99.9% uptime for critical operations |
| Performance | <1s local, <5s API, <500ms MCP, <30s setup wizard |
| Scalability | Unlimited accounts, 1000+ resources/service, 10+ concurrent ops |
| Maintainability | Modular architecture, easy extension (see `extension.md`) |
| Compatibility | macOS, Linux, Windows |
| Auditability | Complete audit trails for all operations |

## Quality Standards (Mandatory)

All code changes MUST maintain these standards:

**Platforms**: SonarCloud (A-grade), CodeFactor (A-grade, 80%+ A-grade files), GitHub Actions (all checks pass), ShellCheck (zero violations)

**Metrics**: Zero security vulnerabilities, zero code duplication (0.0%), <400 code smells, professional shell scripting practices

**Validation process**:

1. **Pre-commit**: ShellCheck on all modified shell scripts
2. **Post-commit**: Verify SonarCloud and CodeFactor improvements
3. **Continuous**: Monitor quality platforms for regressions

```bash
# SonarCloud status
curl -s "https://sonarcloud.io/api/measures/component?component=marcusquinn_aidevops&metricKeys=bugs,vulnerabilities,code_smells"

# CodeFactor status
curl -s "https://www.codefactor.io/repository/github/marcusquinn/aidevops"

# ShellCheck validation
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;
```

## Service Categories

Full service catalogue with helpers, configs, and docs: `services.md`

**Categories**: Infrastructure (Hostinger, Hetzner, Closte, Cloudron), Deployment (Coolify), Content (MainWP), Security (Vaultwarden), Code Quality (CodeRabbit, CodeFactor, Codacy, SonarCloud), Git (GitHub, GitLab, Gitea, Local), Email (Amazon SES), DNS (Cloudflare, Namecheap, Route 53), Domains/Registrars (Spaceship, 101domains), Dev/Local (Localhost, LocalWP, Context7 MCP, MCP Servers)

## Security Requirements

Full security requirements, incident response, and compliance: `security-requirements.md`

**Summary**: Encryption at rest, HTTPS/TLS transmission, role-based access, audit logging, credential rotation. Input validation, output sanitization, confirmation prompts for destructive ops, rate limiting, secure error messages. Restricted file permissions, process isolation, resource limits, vulnerability management.

## Integration Requirements

### MCP Server Integration

- Real-time data access from all integrated services
- Encrypted communications, graceful degradation when unavailable
- Efficient caching, multi-server coordination

### External Service Integration

- REST and GraphQL API support
- Multiple auth methods (tokens, OAuth, API keys)
- Webhook support, batch operations, automatic retry with exponential backoff

### AI Assistant Integration

- Rich context for AI decision making
- AI-generated command validation before execution
- Operation results fed back to AI systems

## Monitoring & Observability

- **Health**: Regular service health checks, performance metrics, error rate tracking, dependency monitoring
- **Audit**: Complete operation logs, access tracking, change management, compliance reporting, data retention
- **Alerting**: Critical error alerts, performance degradation warnings, security event notifications, maintenance windows
