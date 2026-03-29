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
- **Tools**: `rg` (ripgrep), `gh` CLI, bash — no MCP required
- **Search patterns**: use actual code, not keywords (`useState(` not `react hooks`)
- **Be specific**: "JWT token validation middleware" beats "auth"
- **Filter by language**: reduces noise significantly
- **Check tests**: test files often show correct usage patterns

<!-- AI-CONTEXT-END -->

## Search Methods

### 1. GitHub Code Search (via gh CLI)

```bash
gh search code "pattern" --limit 10
gh search code "useState(" --language typescript --limit 10
gh search code "getServerSession" --repo nextauthjs/next-auth --limit 10
gh search code "middleware" --filename "*.ts" --limit 10
```

### 2. Local Repository Search (via ripgrep)

```bash
rg "pattern" --type ts
rg -i "pattern" --type py                          # case-insensitive
rg -C 3 "pattern" --type js                        # with context lines
rg "useState\(.*loading" --type tsx                # regex
rg "pattern" -t ts -t tsx -t js                    # multiple types
rg "pattern" --glob '!node_modules' --glob '!dist' # exclude dirs
```

### 3. Clone and Search

```bash
gh repo clone vercel/next.js -- --depth 1
rg "getServerSession" next.js/
rm -rf next.js
```

## Common Patterns

```bash
# React
rg "useEffect\(\(\) => \{" --type tsx -C 2
rg "class.*ErrorBoundary" --type tsx
rg "createContext<" --type tsx

# API / Auth / DB
rg "app\.(use|get|post)\(" --type ts
rg "getServerSession|getSession" --type ts
rg "prisma\.\w+\.(find|create|update)" --type ts

# Config
rg "module\.exports.*=.*\{" next.config.js
rg '"compilerOptions"' tsconfig.json -A 20
rg '"scripts"' package.json -A 10
```

## vs GitHub Search MCPs

| Feature | github-search (this) | grep_app / gh_grep MCP |
|---------|---------------------|------------------------|
| Token cost | 0 (no MCP) | ~600 tokens |
| Speed | Fast (local rg) | Network dependent |
| Scope | Local + gh CLI | GitHub API |
| Regex | Full ripgrep | Limited |
| Offline | Partial (local) | No |

aidevops does not install GitHub search MCPs. If you have Oh-My-OpenCode, it provides `grep_app`. This subagent is the built-in zero-overhead alternative — use it when you don't have Oh-My-OpenCode or prefer CLI-native search.
