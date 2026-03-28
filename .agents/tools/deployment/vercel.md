---
description: Vercel CLI for serverless deployment
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

# Vercel CLI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `vercel` (install: `npm i -g vercel`)
- **Auth**: `vercel login` → `vercel whoami`
- **Config**: `configs/vercel-cli-config.json`
- **Script**: `.agents/scripts/vercel-cli-helper.sh`
- **Local Dev First**: Works without auth for immediate development

**Commands**: `list-projects|deploy|get-project|list-deployments|list-env|add-env|remove-env|list-domains|add-domain|list-accounts|whoami|dev|build`

**Usage**: `./.agents/scripts/vercel-cli-helper.sh [command] [account] [args]`

**Environments**: development, preview, production
**Frameworks**: Next.js, React, Vue, Nuxt, Svelte, Angular, static sites

**Local Dev** (no auth): `./.agents/scripts/vercel-cli-helper.sh dev personal ./app 3000`
<!-- AI-CONTEXT-END -->

## Prerequisites

```bash
npm i -g vercel
vercel login && vercel whoami
```

Requires: `jq`, Node.js 16+.

## Configuration

```bash
cp configs/vercel-cli-config.json.txt configs/vercel-cli-config.json
```

```json
{
  "accounts": {
    "personal": { "team_name": "Personal", "team_id": "", "default_environment": "preview" },
    "company": { "team_name": "Company Name", "team_id": "team_abc123def456", "default_environment": "preview" }
  },
  "projects": {
    "my-app": {
      "account": "personal",
      "framework": "nextjs",
      "build_command": "npm run build",
      "output_directory": "dist",
      "install_command": "npm ci",
      "node_version": "18.x",
      "domains": ["example.com"]
    }
  }
}
```

Set `team_id` to the Vercel team slug for team accounts; leave empty for personal.

## Usage

### Project Management

```bash
./.agents/scripts/vercel-cli-helper.sh list-projects personal
./.agents/scripts/vercel-cli-helper.sh get-project personal my-app
./.agents/scripts/vercel-cli-helper.sh list-deployments personal my-app 10
```

### Deploy

```bash
# Local dev — no auth required; auto-detects Node.js, static HTML, or npm scripts
./.agents/scripts/vercel-cli-helper.sh dev personal ./app 3000
./.agents/scripts/vercel-cli-helper.sh build personal ./app

# Cloud deploy — requires auth
./.agents/scripts/vercel-cli-helper.sh deploy personal ./app preview
./.agents/scripts/vercel-cli-helper.sh deploy personal ./app production
```

### Environment Variables

```bash
./.agents/scripts/vercel-cli-helper.sh list-env personal my-app development
./.agents/scripts/vercel-cli-helper.sh add-env personal my-app API_KEY "secret-value" production
./.agents/scripts/vercel-cli-helper.sh remove-env personal my-app OLD_VAR production
```

### Domain Management

```bash
./.agents/scripts/vercel-cli-helper.sh list-domains personal
./.agents/scripts/vercel-cli-helper.sh add-domain personal my-app example.com
```

### Account Management

```bash
./.agents/scripts/vercel-cli-helper.sh list-accounts
./.agents/scripts/vercel-cli-helper.sh whoami
```

## CI/CD (GitHub Actions)

```yaml
name: Deploy to Vercel
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./.agents/scripts/vercel-cli-helper.sh deploy production ./ production
        env:
          VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
```

## Security

- Tokens in environment variables, never in version control; rotate regularly
- Team-scoped tokens for organisation projects
- Separate env var values per environment (development/preview/production)
- HTTPS for all custom domains

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Auth failed | `vercel login && vercel whoami` |
| Team access denied | Verify `team_id` in config; check team membership |
| Build failure | `vercel logs [deployment-url]`; check build command and output dir |
| Domain not resolving | Verify DNS settings and domain ownership |

**Debug mode:**

```bash
export DEBUG=1
./.agents/scripts/vercel-cli-helper.sh deploy personal ./app
```

## Monitoring

```bash
vercel logs [deployment-url]
vercel inspect [deployment-url]
```

Built-in: Web Analytics, Speed Insights, Real User Monitoring. For direct REST access, see the [Vercel API docs](https://vercel.com/docs/rest-api).
