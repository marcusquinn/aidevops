---
description: Token-efficient AI context generation tool
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
note: Uses repomix CLI directly (not MCP) for better control and reliability
---

# Context Builder - Token-Efficient AI Context Generation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate token-efficient context for AI coding assistants
- **Tool**: Repomix CLI via helper script or direct `npx repomix` commands
- **Key Feature**: Tree-sitter compression (~80% token reduction)
- **Output**: `~/.aidevops/.agent-workspace/work/context/{repo}-{mode}-{timestamp}.{format}`
- **Invocation**: `@context-builder compress ~/projects/myapp` or call helper directly

### Helper Script

```bash
~/.aidevops/agents/scripts/context-builder-helper.sh <command> [args]
```

| Command | Usage | Notes |
|---------|-------|-------|
| `compress [path]` | Extract code structure only (signatures, imports) | **Recommended** — ~80% token reduction |
| `pack [path] [xml\|markdown\|json]` | Full pack with smart defaults | XML default, best for Claude |
| `quick [path] [pattern]` | Auto-copies to clipboard | Fast, focused subset |
| `analyze [path] [threshold]` | Token usage per file | Default threshold: 100 tokens |
| `remote user/repo [branch]` | Pack remote GitHub repo | See guardrails below |
| `compare [path]` | Full vs compressed side-by-side | Shows size reduction % |

### Direct CLI (when helper unavailable)

```bash
npx repomix@latest . --compress --output context.xml       # Compressed pack
npx repomix@latest --remote user/repo --compress            # Remote repo
npx repomix@latest . --include "src/**/*.ts" --ignore "**/*.test.ts"  # Filtered
npx repomix@latest . --token-count-tree 100                 # Token analysis
npx repomix@latest . --stdout | pbcopy                      # Pipe to clipboard
```

### Mode Selection

| Scenario | Command | Token Impact |
|----------|---------|--------------|
| Architecture understanding | `compress` | ~80% reduction |
| Full implementation details | `pack` | Full tokens |
| Quick file subset | `quick . "**/*.ts"` | Minimal |
| External repo analysis | `remote user/repo` | Compressed |

### Token Budget

| Context Size | Mode | Typical Use |
|--------------|------|-------------|
| < 10k tokens | `pack` | Small projects, specific files |
| 10-50k tokens | `compress` | Medium projects |
| 50k+ tokens | `compress` + patterns | Large projects, selective |

## CRITICAL: Remote Repository Guardrails

**NEVER blindly pack a remote repository.** Escalation:

1. **Fetch README first**: `gh api repos/{owner}/{repo}/readme --jq '.content' | base64 -d` (~1-5K tokens)
2. **Check repo size**: `gh api repos/{user}/{repo} --jq '.size'` (size in KB)
3. **Apply thresholds**:

| Repo Size (KB) | Est. Tokens | Action |
|----------------|-------------|--------|
| < 500 | < 50K | Safe for compressed pack |
| 500-2000 | 50-200K | Use `--include` patterns only |
| > 2000 | > 200K | **NEVER full pack** — targeted files only |

4. **Use patterns**:

```bash
npx repomix@latest --remote user/repo --include "README.md,src/**/*.ts,docs/**" --compress
```

**Dangerous** — packs entire repo without size check:

```bash
# DON'T DO THIS
npx repomix@latest --remote https://github.com/some/large-repo
```

See `tools/context/context-guardrails.md` for full workflow and recovery procedures.

<!-- AI-CONTEXT-END -->

## Usage Examples

```bash
# Large projects: compression + patterns
context-builder-helper.sh compress . --include "src/**/*.ts"

# Monorepos: target specific packages
context-builder-helper.sh compress packages/core

# Debugging: pack only relevant directories
context-builder-helper.sh pack src/services markdown

# Remote repos with branch
context-builder-helper.sh remote vercel/next.js canary
```

**Compress mode** extracts class/function signatures, interface definitions, import/export statements — omits implementation bodies, comments, empty lines.

## Troubleshooting

- **"npx not found"**: `brew install node`
- **"Permission denied"**: `chmod +x ~/.aidevops/agents/scripts/context-builder-helper.sh`
- **Large output**: Use `compress` mode or filter with `--include`/`--ignore` patterns

## Related

- [Repomix Documentation](https://repomix.com/guide/)
- `tools/context/context-guardrails.md` — remote repo safety workflow

**Note on MCP**: Repomix supports MCP server mode (`npx repomix --mcp`), but this framework uses the CLI directly for better control and reliability.
