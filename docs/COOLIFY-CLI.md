# Coolify CLI Integration

Comprehensive self-hosted deployment and management using the Coolify CLI through the AI DevOps Framework.

## Overview

The Coolify CLI helper provides complete automation for:

- **Local Development**: Works without Coolify setup for immediate development
- Self-hosted application deployment and management
- Server provisioning and management
- Database creation and backup management
- Multi-environment deployment workflows
- Docker container orchestration

### 🚀 **Local Development First**

The integration is designed to work **immediately** for local development without requiring Coolify setup:

- **Node.js Projects**: Automatically detects and runs `npm run dev` or `npm run start`
- **Docker Projects**: Supports Dockerfile and docker-compose.yml
- **Static HTML**: Serves static files using Python HTTP server
- **Universal Build**: Runs local build scripts without cloud dependencies

## Prerequisites

### Install Coolify CLI

```bash
# Using install script (recommended)
curl -fsSL https://raw.githubusercontent.com/coollabsio/coolify-cli/main/scripts/install.sh | bash

# Using Go
go install github.com/coollabsio/coolify-cli/coolify@latest
```

### Dependencies

- **Coolify CLI**: Latest version
- **jq**: JSON processor for configuration management
- **Docker**: For Docker-based projects (optional)
- **Node.js**: For Node.js projects (optional)

## Configuration

### Setup Configuration File

```bash
# Copy template
cp configs/coolify-cli-config.json.txt configs/coolify-cli-config.json

# Edit configuration
nano configs/coolify-cli-config.json
```

### Add Coolify Context

```bash
# Add production context
./providers/coolify-cli-helper.sh add-context production https://coolify.example.com your-api-token true

# Add staging context
./providers/coolify-cli-helper.sh add-context staging https://staging.coolify.example.com staging-token

# List contexts
./providers/coolify-cli-helper.sh list-contexts
```

## Usage Examples

### Local Development (No Coolify Required)

```bash
# Start development server (works immediately)
./providers/coolify-cli-helper.sh dev local ./my-app 3000

# Build project locally
./providers/coolify-cli-helper.sh build local ./my-app

# Works with any project type:
# - Node.js projects with package.json
# - Docker projects with Dockerfile or docker-compose.yml
# - Static HTML files
# - Any framework with npm scripts
```

### Application Management

```bash
# List applications
./providers/coolify-cli-helper.sh list-apps production

# Deploy application by name
./providers/coolify-cli-helper.sh deploy production my-app

# Force deploy
./providers/coolify-cli-helper.sh deploy production my-app true

# Get application details
./providers/coolify-cli-helper.sh get-app production app-uuid-here
```

### Server Management

```bash
# List servers
./providers/coolify-cli-helper.sh list-servers production

# Add new server
./providers/coolify-cli-helper.sh add-server production myserver 192.168.1.100 key-uuid 22 root true

# Parameters: context name ip key-uuid port user validate
```

### Database Management

```bash
# List databases
./providers/coolify-cli-helper.sh list-databases production

# Create PostgreSQL database
./providers/coolify-cli-helper.sh create-db production postgresql server-uuid project-uuid main mydb true

# Parameters: context type server-uuid project-uuid environment name instant-deploy
```

## Advanced Features

### Multi-Context Management

Configure multiple Coolify instances:

```json
{
  "contexts": {
    "local": {
      "url": "http://localhost:8000",
      "description": "Local development"
    },
    "staging": {
      "url": "https://staging.coolify.example.com",
      "description": "Staging environment"
    },
    "production": {
      "url": "https://coolify.example.com",
      "description": "Production environment"
    }
  }
}
```

### Project Configuration

Define project-specific settings:

```json
{
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

### Docker Support

Full Docker integration:

```bash
# Docker Compose projects
./providers/coolify-cli-helper.sh dev local ./docker-app 3000

# Dockerfile projects
./providers/coolify-cli-helper.sh build local ./docker-app
```

## Integration with CI/CD

### GitHub Actions Integration

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
      - name: Deploy to Coolify
        run: |
          ./providers/coolify-cli-helper.sh deploy production my-app true
        env:
          COOLIFY_TOKEN: ${{ secrets.COOLIFY_TOKEN }}
```

### Multi-Environment Deployments

```bash
# Development
./providers/coolify-cli-helper.sh dev local ./app 3000

# Staging deployment
./providers/coolify-cli-helper.sh deploy staging my-app

# Production deployment
./providers/coolify-cli-helper.sh deploy production my-app
```

## Database Management

### Supported Database Types

- **PostgreSQL**: Full-featured relational database
- **MySQL/MariaDB**: Popular relational databases
- **MongoDB**: Document database
- **Redis**: In-memory data store
- **ClickHouse**: Columnar database
- **KeyDB**: Redis-compatible database

### Database Operations

```bash
# Create databases
./providers/coolify-cli-helper.sh create-db production postgresql server-uuid project-uuid main postgres-db true
./providers/coolify-cli-helper.sh create-db production redis server-uuid project-uuid main redis-cache true
./providers/coolify-cli-helper.sh create-db production mongodb server-uuid project-uuid main mongo-db true
```

## Security Best Practices

### API Token Management

- Store Coolify tokens securely in environment variables
- Use context-specific tokens for different environments
- Rotate tokens regularly for security

### Server Security

- Use SSH key authentication for server access
- Configure proper firewall rules
- Enable SSL/TLS for all applications
- Regular security updates

### Network Security

- Use private networks for database connections
- Configure proper port mappings
- Enable IP whitelisting when needed

## Troubleshooting

### Common Issues

1. **CLI Not Found**

   ```bash
   curl -fsSL https://raw.githubusercontent.com/coollabsio/coolify-cli/main/scripts/install.sh | bash
   ```

2. **Context Issues**

   ```bash
   ./providers/coolify-cli-helper.sh list-contexts
   ./providers/coolify-cli-helper.sh add-context production https://coolify.example.com token
   ```

3. **Local Development Issues**
   - Check if Node.js/Docker is installed
   - Verify project structure (package.json, Dockerfile, etc.)
   - Check port availability

4. **Deployment Failures**
   - Verify server connectivity
   - Check application logs
   - Validate environment variables

### Debug Mode

Enable verbose logging:

```bash
# Set debug environment variable
export DEBUG=1
./providers/coolify-cli-helper.sh deploy production my-app
```

## Framework Support

Coolify CLI helper supports all major frameworks and deployment types:

- **Node.js**: Express, Next.js, Nuxt.js, NestJS
- **PHP**: Laravel, Symfony, WordPress
- **Python**: Django, Flask, FastAPI
- **Docker**: Any containerized application
- **Static Sites**: HTML, CSS, JavaScript
- **Databases**: PostgreSQL, MySQL, MongoDB, Redis

## Performance Optimization

### Build Optimization

- Use appropriate base images
- Configure build caching
- Optimize container layers
- Enable compression

### Deployment Speed

- Use incremental deployments
- Configure proper health checks
- Optimize resource allocation

## Monitoring and Logging

### Built-in Monitoring

- Application health checks
- Resource usage monitoring
- Log aggregation
- Uptime monitoring

### Custom Monitoring

```bash
# View application logs
coolify app logs app-uuid

# Monitor deployments
coolify deploy list

# Check server resources
coolify server get server-uuid --resources
```

## API Integration

The helper script integrates with Coolify's REST API for advanced operations:

- Application lifecycle management
- Server provisioning and management
- Database operations
- Backup management
- Team and user management

For direct API access, see the [Coolify API documentation](https://coolify.io/docs/api).
