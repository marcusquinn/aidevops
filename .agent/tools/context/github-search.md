---
description: Search GitHub repositories for code patterns using ripgrep and bash
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# GitHub Code Search

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Find real-world code examples from public GitHub repositories
- **Tools**: `rg` (ripgrep), `gh` CLI, bash
- **No MCP required**: Uses standard CLI tools

**When to use**:

- Finding implementation patterns for unfamiliar APIs
- Discovering how libraries are used in production
- Learning correct syntax and configuration
- Understanding how different tools work together

**Search patterns** (use actual code, not keywords):

- Good: `useState(`, `import React from`, `async function`
- Bad: `react tutorial`, `best practices`, `how to use`

<!-- AI-CONTEXT-END -->

## Search Methods

### 1. GitHub Code Search (via gh CLI)

Search across all public GitHub repositories:

```bash
# Basic search
gh search code "pattern" --limit 10

# Filter by language
gh search code "useState(" --language typescript --limit 10

# Filter by repository
gh search code "getServerSession" --repo nextauthjs/next-auth --limit 10

# Filter by file path
gh search code "middleware" --filename "*.ts" --limit 10
```

### 2. Local Repository Search (via ripgrep)

Search within cloned repositories:

```bash
# Basic pattern search
rg "pattern" --type ts

# Case-insensitive
rg -i "pattern" --type py

# With context lines
rg -C 3 "pattern" --type js

# Regex patterns
rg "useState\(.*loading" --type tsx

# Multiple file types
rg "pattern" -t ts -t tsx -t js

# Exclude directories
rg "pattern" --glob '!node_modules' --glob '!dist'
```

### 3. Clone and Search Pattern

For deeper analysis, clone popular repositories:

```bash
# Clone a specific repo
gh repo clone vercel/next.js -- --depth 1

# Search within it
rg "getServerSession" next.js/

# Clean up
rm -rf next.js
```

## Common Search Patterns

### React Patterns

```bash
# Hooks usage
rg "useEffect\(\(\) => \{" --type tsx -C 2

# Error boundaries
rg "class.*ErrorBoundary" --type tsx

# Context providers
rg "createContext<" --type tsx
```

### API Patterns

```bash
# Express middleware
rg "app\.(use|get|post)\(" --type ts

# Authentication
rg "getServerSession|getSession" --type ts

# Database queries
rg "prisma\.\w+\.(find|create|update)" --type ts
```

### Configuration Patterns

```bash
# Next.js config
rg "module\.exports.*=.*\{" next.config.js

# TypeScript config
rg '"compilerOptions"' tsconfig.json -A 20

# Package scripts
rg '"scripts"' package.json -A 10
```

## Tips

1. **Be specific**: More words = better results. "auth" is vague, "JWT token validation middleware" is specific.

2. **Use actual code**: Search for code patterns that would appear in files, not descriptions.

3. **Filter by language**: Reduces noise significantly.

4. **Check popular repos**: Well-maintained repos have better patterns.

5. **Look at tests**: Test files often show correct usage patterns.

## Comparison with gh_grep MCP

| Feature | github-search (this) | gh_grep MCP |
|---------|---------------------|-------------|
| Token cost | 0 (no MCP) | ~600 tokens |
| Speed | Fast (local rg) | Network dependent |
| Scope | Local + gh CLI | GitHub API |
| Regex | Full ripgrep | Limited |
| Offline | Partial (local) | No |

This subagent provides the same functionality as `gh_grep` MCP without the token overhead.
