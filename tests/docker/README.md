# Docker Test Environment

Minimal Alpine-based environment for testing setup scripts.

## Quick Start

```bash
cd tests/docker

# Run all tests
docker-compose run --rm test

# Interactive shell for debugging
docker-compose run --rm shell

# Build fresh
docker-compose build --no-cache
```

## What's Tested

- Syntax validation for all 87+ scripts
- generate-opencode-agents.sh (help, status, install)
- setup-local-api-keys.sh (help, list, set)
- setup-mcp-integrations.sh (help)
