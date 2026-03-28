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

# Coolify CLI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Self-hosted PaaS for Docker deployment
- **Install**: `curl -fsSL https://raw.githubusercontent.com/coollabsio/coolify-cli/main/scripts/install.sh | bash`
- **Config**: `configs/coolify-cli-config.json`
- **Script**: `.agents/scripts/coolify-cli-helper.sh`
- **Local Dev First**: Works without Coolify setup

**Commands**: `add-context|list-contexts|list-apps|deploy|get-app|list-servers|add-server|list-databases|create-db|dev|build`

**Usage**: `./.agents/scripts/coolify-cli-helper.sh [command] [context] [args]`

**Databases**: PostgreSQL, MySQL, MongoDB, Redis, ClickHouse, KeyDB
**Frameworks**: Node.js, PHP, Python, Docker, static sites

**Local Dev** (no Coolify): `./.agents/scripts/coolify-cli-helper.sh dev local ./app 3000`
<!-- AI-CONTEXT-END -->

## Prerequisites

Install Coolify CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/coollabsio/coolify-cli/main/scripts/install.sh | bash
# or: go install github.com/coollabsio/coolify-cli/coolify@latest
```

Dependencies: `jq` (required), `docker` (optional), `node` (optional).

## Configuration

```bash
# Copy template and edit
cp configs/coolify-cli-config.json.txt configs/coolify-cli-config.json

# Add contexts
./.agents/scripts/coolify-cli-helper.sh add-context production https://coolify.example.com your-api-token true
./.agents/scripts/coolify-cli-helper.sh add-context staging https://staging.coolify.example.com staging-token
./.agents/scripts/coolify-cli-helper.sh list-contexts
```

Multi-context config (`configs/coolify-cli-config.json`):

```json
{
  "contexts": {
    "local":      { "url": "http://localhost:8000" },
    "staging":    { "url": "https://staging.coolify.example.com" },
    "production": { "url": "https://coolify.example.com" }
  },
  "projects": {
    "web-app": {
      "context": "production",
      "type": "nodejs",
      "git_repository": "https://github.com/user/web-app.git",
      "build_command": "npm run build",
      "start_command": "npm start",
      "domains": ["app.example.com"]
    }
  }
}
```

## Usage

### Local Development (no Coolify required)

Auto-detects project type (Node.js `package.json`, Dockerfile/docker-compose, static HTML):

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
name: Deploy to Coolify
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./.agents/scripts/coolify-cli-helper.sh deploy production my-app true
        env:
          COOLIFY_TOKEN: ${{ secrets.COOLIFY_TOKEN }}
```

## Monitoring

```bash
coolify app logs app-uuid
coolify deploy list
coolify server get server-uuid --resources
```

API docs: https://coolify.io/docs/api

## Troubleshooting

| Issue | Fix |
|-------|-----|
| CLI not found | Re-run install script above |
| Context issues | `list-contexts` then `add-context` |
| Local dev fails | Check Node.js/Docker installed; verify `package.json`/`Dockerfile` present; check port availability |
| Deployment fails | Verify server connectivity; check app logs; validate env vars |

Debug mode: `export DEBUG=1` before any command.

**Security**: Store tokens in env vars or `aidevops secret`. Use context-specific tokens per environment.
