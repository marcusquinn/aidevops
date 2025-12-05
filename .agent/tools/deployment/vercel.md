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
  list: true
  webfetch: true
---

# Vercel CLI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `vercel` (install: `npm i -g vercel`)
- **Auth**: `vercel login` → `vercel whoami`
- **Config**: `configs/vercel-cli-config.json`
- **Script**: `.agent/scripts/vercel-cli-helper.sh`
- **Local Dev First**: Works without auth for immediate development

**Commands**: `list-projects|deploy|get-project|list-deployments|list-env|add-env|remove-env|list-domains|add-domain|list-accounts|whoami|dev|build`

**Usage**: `./.agent/scripts/vercel-cli-helper.sh [command] [account] [args]`

**Environments**: development, preview, production
**Frameworks**: Next.js, React, Vue, Nuxt, Svelte, Angular, static sites

**Local Dev** (no auth): `./.agent/scripts/vercel-cli-helper.sh dev personal ./app 3000`
<!-- AI-CONTEXT-END -->

Comprehensive Vercel deployment and project management using the Vercel CLI through the AI DevOps Framework.

## Overview

The Vercel CLI helper provides complete automation for:

- **Local Development**: Works without authentication for immediate setup
- Project deployment and management
- Environment variable configuration
- Domain management and SSL setup
- Team and account management
- Deployment monitoring and rollbacks

### 🚀 **Local Development First**

The integration is designed to work **immediately** for local development without requiring Vercel authentication:

- **Node.js Projects**: Automatically detects and runs `npm run dev` or `npm run start`
- **Static HTML**: Serves static files using Python HTTP server
- **Next.js/React**: Full framework support with hot reloading
- **Universal Build**: Runs local build scripts without cloud dependencies

## Prerequisites

### Install Vercel CLI

```bash
# Using npm
npm i -g vercel

# Using yarn
yarn global add vercel

# Using pnpm
pnpm add -g vercel
```

### Authentication

```bash
# Login to Vercel
vercel login

# Verify authentication
vercel whoami
```

### Dependencies

- **Vercel CLI**: Latest version
- **jq**: JSON processor for configuration management
- **Node.js**: Version 16+ recommended

## Configuration

### Setup Configuration File

```bash
# Copy template
cp configs/vercel-cli-config.json.txt configs/vercel-cli-config.json

# Edit configuration
nano configs/vercel-cli-config.json
```

### Configuration Structure

```json
{
  "accounts": {
    "personal": {
      "team_name": "Personal",
      "team_id": "",
      "description": "Personal account",
      "default_environment": "preview"
    },
    "company": {
      "team_name": "Company Name",
      "team_id": "team_abc123",
      "description": "Company team account",
      "default_environment": "preview"
    }
  },
  "projects": {
    "my-app": {
      "account": "personal",
      "framework": "nextjs",
      "domains": ["example.com"]
    }
  }
}
```

## Usage Examples

### Project Management

```bash
# List all projects
./.agent/scripts/vercel-cli-helper.sh list-projects personal

# Deploy to preview environment
./.agent/scripts/vercel-cli-helper.sh deploy personal ./my-app preview

# Deploy to production
./.agent/scripts/vercel-cli-helper.sh deploy personal ./my-app production

# Get project information
./.agent/scripts/vercel-cli-helper.sh get-project personal my-app

# List recent deployments
./.agent/scripts/vercel-cli-helper.sh list-deployments personal my-app 10
```

### Environment Variables

```bash
# List environment variables
./.agent/scripts/vercel-cli-helper.sh list-env personal my-app development

# Add environment variable
./.agent/scripts/vercel-cli-helper.sh add-env personal my-app API_KEY "secret-value" production

# Remove environment variable
./.agent/scripts/vercel-cli-helper.sh remove-env personal my-app OLD_VAR production
```

### Domain Management

```bash
# List domains
./.agent/scripts/vercel-cli-helper.sh list-domains personal

# Add domain to project
./.agent/scripts/vercel-cli-helper.sh add-domain personal my-app example.com
```

### Account Management

```bash
# List configured accounts
./.agent/scripts/vercel-cli-helper.sh list-accounts

# Show current Vercel user
./.agent/scripts/vercel-cli-helper.sh whoami
```

## Advanced Features

### Team Management

For team accounts, configure the `team_id` in your account configuration:

```json
{
  "accounts": {
    "company": {
      "team_name": "My Company",
      "team_id": "team_abc123def456",
      "description": "Company Vercel team"
    }
  }
}
```

### Custom Build Configuration

Configure project-specific build settings:

```json
{
  "projects": {
    "my-app": {
      "build_command": "npm run build",
      "output_directory": "dist",
      "install_command": "npm ci",
      "node_version": "18.x"
    }
  }
}
```

### Local Development (No Authentication Required)

Perfect for immediate development without any setup:

```bash
# Start development server (works immediately)
./.agent/scripts/vercel-cli-helper.sh dev personal ./my-app 3000

# Build project locally
./.agent/scripts/vercel-cli-helper.sh build personal ./my-app

# Works with any project type:
# - Node.js projects with package.json
# - Static HTML files
# - Next.js, React, Vue, Svelte
# - Any framework with npm scripts
```

### Multiple Environments

Support for development, preview, and production environments:

```bash
# Local development (no auth required)
./.agent/scripts/vercel-cli-helper.sh dev personal ./app 3000

# Deploy to specific environments (requires auth)
./.agent/scripts/vercel-cli-helper.sh deploy personal ./app development
./.agent/scripts/vercel-cli-helper.sh deploy personal ./app preview
./.agent/scripts/vercel-cli-helper.sh deploy personal ./app production
```

## Integration with CI/CD

### GitHub Actions Integration

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
      - name: Deploy to Vercel
        run: |
          ./.agent/scripts/vercel-cli-helper.sh deploy production ./ production
        env:
          VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
```

### Environment-Specific Deployments

```bash
# Preview deployments for feature branches
./.agent/scripts/vercel-cli-helper.sh deploy personal ./app preview

# Production deployments for main branch
./.agent/scripts/vercel-cli-helper.sh deploy personal ./app production
```

## Security Best Practices

### Token Management

- Store Vercel tokens securely in environment variables
- Use team-scoped tokens for organization projects
- Rotate tokens regularly

### Environment Variables

- Use different values for development, preview, and production
- Store sensitive values in Vercel's encrypted environment variables
- Never commit secrets to version control

### Domain Security

- Enable HTTPS for all custom domains
- Configure proper security headers
- Use Vercel's DDoS protection features

## Troubleshooting

### Common Issues

1. **Authentication Failed**

   ```bash
   vercel login
   vercel whoami
   ```

2. **Team Access Issues**
   - Verify team_id in configuration
   - Check team membership permissions

3. **Build Failures**
   - Check build logs: `vercel logs [deployment-url]`
   - Verify build command and output directory

4. **Domain Configuration**
   - Verify DNS settings
   - Check domain ownership

### Debug Mode

Enable verbose logging:

```bash
# Set debug environment variable
export DEBUG=1
./.agent/scripts/vercel-cli-helper.sh deploy personal ./app
```

## Framework Support

Vercel CLI helper supports all major frameworks:

- **Next.js**: Full-stack React framework
- **React**: Client-side React applications
- **Vue.js**: Progressive JavaScript framework
- **Nuxt.js**: Vue.js framework
- **Svelte/SvelteKit**: Modern web framework
- **Angular**: TypeScript-based framework
- **Static Sites**: HTML, CSS, JavaScript

## Performance Optimization

### Build Optimization

- Use appropriate Node.js version
- Configure build caching
- Optimize bundle size
- Enable compression

### Deployment Speed

- Use incremental builds
- Configure proper ignore patterns
- Optimize asset delivery

## Monitoring and Analytics

### Built-in Analytics

- Web Analytics for traffic insights
- Speed Insights for performance monitoring
- Real User Monitoring (RUM)

### Custom Monitoring

```bash
# View deployment logs
vercel logs [deployment-url]

# Monitor function performance
vercel inspect [deployment-url]
```

## API Integration

The helper script integrates with Vercel's REST API for advanced operations:

- Project management
- Deployment automation
- Team administration
- Usage analytics

For direct API access, see the [Vercel API documentation](https://vercel.com/docs/rest-api).
