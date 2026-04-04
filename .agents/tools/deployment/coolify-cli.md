---
description: Coolify CLI for deployment management
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Coolify CLI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Self-hosted PaaS for Docker deployment
- **Install**: `curl -fsSL https://raw.githubusercontent.com/coollabsio/coolify-cli/main/scripts/install.sh | bash` (or `go install github.com/coollabsio/coolify-cli/coolify@latest`)
- **Config**: `configs/coolify-cli-config.json` (copy from `.json.txt` template)
- **Script**: `.agents/scripts/coolify-cli-helper.sh`
- **Deps**: `jq` (required), `docker` (optional), `node` (optional)
- **Debug**: `export DEBUG=1` before any command
- **Security**: Store tokens in env vars or `aidevops secret`. Use context-specific tokens per environment.
- **API docs**: https://coolify.io/docs/api
- **Related**: `coolify-setup.md` (server install), `coolify.md` (provider guide, monitoring)

**Commands**: `add-context|list-contexts|list-apps|deploy|get-app|list-servers|add-server|list-databases|create-db|dev|build`

**Usage**: `./.agents/scripts/coolify-cli-helper.sh [command] [context] [args]`

**Databases**: PostgreSQL, MySQL, MongoDB, Redis, ClickHouse, KeyDB
**Frameworks**: Node.js, PHP, Python, Docker, static sites

**Local Dev** (no Coolify): `./.agents/scripts/coolify-cli-helper.sh dev local ./app 3000`

<!-- AI-CONTEXT-END -->

## Configuration

```bash
cp configs/coolify-cli-config.json.txt configs/coolify-cli-config.json

./.agents/scripts/coolify-cli-helper.sh add-context production https://coolify.example.com your-api-token true
./.agents/scripts/coolify-cli-helper.sh add-context staging https://staging.coolify.example.com staging-token
./.agents/scripts/coolify-cli-helper.sh list-contexts
```

Config structure (`configs/coolify-cli-config.json`):

```json
{
  "contexts": {
    "local":      { "url": "http://localhost:8000" },
    "staging":    { "url": "https://staging.coolify.example.com" },
    "production": { "url": "https://coolify.example.com" }
  },
  "projects": {
    "web-app": { "context": "production", "type": "nodejs", "domains": ["app.example.com"] }
  }
}
```

## Usage

### Local Development (no Coolify required)

Auto-detects project type (`package.json`, `Dockerfile`/`docker-compose`, static HTML):

```bash
./.agents/scripts/coolify-cli-helper.sh dev local ./my-app 3000
./.agents/scripts/coolify-cli-helper.sh build local ./my-app
```

### Application Management

```bash
./.agents/scripts/coolify-cli-helper.sh list-apps production
./.agents/scripts/coolify-cli-helper.sh deploy production my-app          # deploy
./.agents/scripts/coolify-cli-helper.sh deploy production my-app true     # force deploy
./.agents/scripts/coolify-cli-helper.sh get-app production app-uuid-here

# Monitoring (native coolify CLI)
coolify app logs app-uuid
coolify deploy list
coolify server get server-uuid --resources
```

### Server Management

```bash
./.agents/scripts/coolify-cli-helper.sh list-servers production
# add-server: context name ip key-uuid port user validate
./.agents/scripts/coolify-cli-helper.sh add-server production myserver 192.168.1.100 key-uuid 22 root true
```

### Database Management

```bash
./.agents/scripts/coolify-cli-helper.sh list-databases production
# create-db: context type server-uuid project-uuid environment name instant-deploy
./.agents/scripts/coolify-cli-helper.sh create-db production postgresql server-uuid project-uuid main mydb true
./.agents/scripts/coolify-cli-helper.sh create-db production redis       server-uuid project-uuid main redis-cache true
./.agents/scripts/coolify-cli-helper.sh create-db production mongodb     server-uuid project-uuid main mongo-db true
```

## CI/CD Integration

```yaml
- run: ./.agents/scripts/coolify-cli-helper.sh deploy production my-app true
  env:
    COOLIFY_TOKEN: ${{ secrets.COOLIFY_TOKEN }}
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| CLI not found | Re-run install script (see Quick Reference) |
| Context issues | `list-contexts` then `add-context` |
| Local dev fails | Check Node.js/Docker installed; verify `package.json`/`Dockerfile` present; check port availability |
| Deployment fails | Verify server connectivity; check app logs; validate env vars |
