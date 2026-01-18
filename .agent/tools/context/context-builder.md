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
---

# Context Builder - Token-Efficient AI Context Generation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate token-efficient context for AI coding assistants
- **Tool**: Repomix wrapper with aidevops conventions
- **Key Feature**: Tree-sitter compression (~80% token reduction)
- **Output Dir**: `~/.aidevops/.agent-workspace/work/context/`

**Commands**:

```bash
# Compress mode (recommended) - extracts code structure only
.agent/scripts/context-builder-helper.sh compress [path]

# Full pack with smart defaults
.agent/scripts/context-builder-helper.sh pack [path] [xml|markdown|json]

# Quick mode - auto-copies to clipboard
.agent/scripts/context-builder-helper.sh quick [path] [pattern]

# Analyze token usage per file
.agent/scripts/context-builder-helper.sh analyze [path] [threshold]

# Pack remote GitHub repo
.agent/scripts/context-builder-helper.sh remote user/repo [branch]

# Compare full vs compressed
.agent/scripts/context-builder-helper.sh compare [path]

# Start MCP server
.agent/scripts/context-builder-helper.sh mcp
```text

**When to Use**:

| Scenario | Command | Token Impact |
|----------|---------|--------------|
| Share full codebase with AI | `pack` | Full tokens |
| Architecture understanding | `compress` | ~80% reduction |
| Quick file subset | `quick . "**/*.ts"` | Minimal |
| External repo analysis | `remote user/repo` | Compressed |

**Code Maps (compress mode)** extracts:
- Class names and signatures
- Function signatures
- Interface definitions
- Import/export statements
- Omits: implementation details, comments, empty lines

## CRITICAL: Remote Repository Guardrails

**NEVER blindly pack a remote repository.** Follow this escalation:

1. **Fetch README first** - `webfetch "https://github.com/{user}/{repo}"` (~1-5K tokens)
2. **Check repo size** - `gh api repos/{user}/{repo} --jq '.size'` (size in KB)
3. **Apply size thresholds**:

| Repo Size (KB) | Est. Tokens | Action |
|----------------|-------------|--------|
| < 500 | < 50K | Safe for compressed pack |
| 500-2000 | 50-200K | Use `includePatterns` only |
| > 2000 | > 200K | **NEVER full pack** - targeted files only |

4. **Use patterns** - `mcp_repomix_pack_remote_repository(..., includePatterns="README.md,src/**/*.ts")`

**What NOT to do:**
```bash
# DANGEROUS - packs entire repo without size check
mcp_repomix_pack_remote_repository(remote="https://github.com/some/large-repo")
```

See `tools/context/context-guardrails.md` for full workflow and recovery procedures.

<!-- AI-CONTEXT-END -->

## Overview

Context Builder wraps [Repomix](https://github.com/yamadashy/repomix) (20k+ GitHub stars) to provide optimized context generation for AI coding assistants. It's inspired by [RepoPrompt](https://repoprompt.com/)'s Code Maps approach.

### The Problem

When asking AI assistants to help with code:
- Copying entire files wastes tokens on implementation details
- AI context windows are limited and expensive
- Manual file selection is tedious and error-prone

### The Solution

Context Builder provides:
- **Tree-sitter compression**: Extract code structure, not implementation
- **Smart defaults**: Optimized for AI understanding
- **Multiple output formats**: XML, Markdown, JSON, Plain
- **Token analysis**: See which files consume the most tokens
- **Remote repo support**: Analyze any GitHub repository

## Installation

The helper script is included in the aidevops framework:

```bash
# Already available at
~/Git/aidevops/.agent/scripts/context-builder-helper.sh

# Or add to PATH
alias context-builder='~/Git/aidevops/.agent/scripts/context-builder-helper.sh'
```text

### Dependencies

- **Node.js 18+** with npx
- **Repomix** (auto-installed via npx)

## Usage Examples

### 1. Compress Mode (Recommended)

Extract code structure with ~80% token reduction:

```bash
# Current directory
./context-builder-helper.sh compress

# Specific project
./context-builder-helper.sh compress ~/projects/myapp

# Output as markdown
./context-builder-helper.sh compress ~/projects/myapp markdown
```text

**What gets extracted**:

```typescript
// Original (full implementation)
export class UserService {
  private db: Database;
  
  constructor(db: Database) {
    this.db = db;
  }
  
  async getUser(id: string): Promise<User | null> {
    const result = await this.db.query('SELECT * FROM users WHERE id = ?', [id]);
    if (result.rows.length === 0) return null;
    return this.mapToUser(result.rows[0]);
  }
  
  private mapToUser(row: any): User {
    return { id: row.id, name: row.name, email: row.email };
  }
}

// Compressed (structure only)
export class UserService {
  private db: Database;
  constructor(db: Database);
  async getUser(id: string): Promise<User | null>;
  private mapToUser(row: any): User;
}
```text

### 2. Full Pack Mode

When you need complete implementation details:

```bash
# XML format (default, best for Claude)
./context-builder-helper.sh pack

# Markdown format
./context-builder-helper.sh pack . markdown

# JSON format (structured data)
./context-builder-helper.sh pack . json
```text

### 3. Quick Mode

Fast, focused context with auto-clipboard:

```bash
# Pack and copy TypeScript files
./context-builder-helper.sh quick . "**/*.ts"

# Pack specific directory
./context-builder-helper.sh quick src/components "**/*.tsx"
```text

### 4. Token Analysis

Understand token distribution before packing:

```bash
# Show files with 100+ tokens
./context-builder-helper.sh analyze

# Lower threshold for detailed view
./context-builder-helper.sh analyze . 50

# Analyze specific project
./context-builder-helper.sh analyze ~/Git/aidevops 100
```text

### 5. Remote Repository

Pack any GitHub repository without cloning:

```bash
# GitHub URL
./context-builder-helper.sh remote https://github.com/facebook/react

# Short format
./context-builder-helper.sh remote facebook/react

# Specific branch
./context-builder-helper.sh remote vercel/next.js canary

# With output format
./context-builder-helper.sh remote sveltejs/svelte main markdown
```text

### 6. Compare Full vs Compressed

See the token reduction in action:

```bash
./context-builder-helper.sh compare ~/projects/myapp
```text

Output:

```text
┌─────────────────────────────────────────────────┐
│              Context Comparison                 │
├─────────────────────────────────────────────────┤
│ Metric               │       Full │ Compressed │
├─────────────────────────────────────────────────┤
│ File Size            │       2.1M │       412K │
│ Lines                │      45230 │       8921 │
└─────────────────────────────────────────────────┘

Size reduction: 80.4%
```text

## MCP Server Integration

Context Builder can run as an MCP server for direct AI assistant integration:

```bash
# Start MCP server
./context-builder-helper.sh mcp
```text

### OpenCode Configuration

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "repomix": {
      "type": "local",
      "command": ["/opt/homebrew/bin/npx", "-y", "repomix@latest", "--mcp"],
      "enabled": true
    }
  }
}
```text

### Available MCP Tools

When running as MCP server:
- `pack_repository` - Pack local or remote repository
- `read_repomix_output` - Read generated context file
- `file_system_tree` - Get directory structure

## Output Files

All output is saved to `~/.aidevops/.agent-workspace/work/context/`:

```text
~/.aidevops/.agent-workspace/work/context/
├── aidevops-full-20250129-143022.xml
├── aidevops-compressed-20250129-143045.xml
├── react-remote-20250129-150000.xml
└── myapp-quick-20250129-151030.md
```text

File naming: `{repo-name}-{mode}-{timestamp}.{format}`

## Best Practices

### When to Use Each Mode

| Mode | Use Case | Token Efficiency |
|------|----------|------------------|
| `compress` | Architecture review, refactoring planning | Best (~80% reduction) |
| `pack` | Debugging specific implementations | Full detail |
| `quick` | Focused questions about specific files | Minimal |
| `remote` | Analyzing external libraries | Compressed by default |
| `analyze` | Understanding large codebases | No output (analysis only) |

### Token Budget Guidelines

| Context Size | Recommended Mode | Typical Use |
|--------------|------------------|-------------|
| < 10k tokens | `pack` | Small projects, specific files |
| 10-50k tokens | `compress` | Medium projects |
| 50k+ tokens | `compress` + patterns | Large projects, selective |

### Effective Patterns

```bash
# For large projects, combine compression with patterns
./context-builder-helper.sh compress . --include "src/**/*.ts"

# For monorepos, target specific packages
./context-builder-helper.sh compress packages/core

# For debugging, pack only relevant directories
./context-builder-helper.sh pack src/services markdown
```text

## Comparison with RepoPrompt

| Feature | Context Builder | RepoPrompt |
|---------|-----------------|------------|
| Code Maps | Yes (Tree-sitter) | Yes (AST) |
| Token Reduction | ~80% | ~80% |
| Visual File Selection | CLI patterns | GUI tree |
| AI Context Builder | Manual | Auto-suggest |
| MCP Integration | Yes | Yes |
| Platform | Cross-platform | macOS only |
| Cost | Free (open source) | Freemium |

## Troubleshooting

### Common Issues

**"npx not found"**

```bash
# Install Node.js
brew install node  # macOS
```text

**"Permission denied"**

```bash
chmod +x ~/.aidevops/agents/scripts/context-builder-helper.sh
```text

**Large output file**

```bash
# Use compression
./context-builder-helper.sh compress

# Or filter files
./context-builder-helper.sh pack . --include "src/**/*.ts" --ignore "**/*.test.ts"
```text

## Integration with AI Assistants

### Claude Code / OpenCode

Use the `@context-builder` subagent or call the helper directly:

```text
@context-builder compress ~/projects/myapp
```text

### Manual Workflow

1. Generate context: `./context-builder-helper.sh compress .`
2. Copy output: `cat ~/.aidevops/.agent-workspace/work/context/myapp-*.xml | pbcopy`
3. Paste into AI conversation with your question

## Related Documentation

- [Repomix Documentation](https://repomix.com/guide/)
- [RepoPrompt Concepts](https://repoprompt.com/docs)
- [aidevops Framework](~/Git/aidevops/AGENTS.md)
