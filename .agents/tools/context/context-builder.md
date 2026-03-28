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
- **Output Dir**: `~/.aidevops/.agent-workspace/work/context/`

**Helper Script Commands**:

```bash
# Compress mode (recommended) - extracts code structure only
~/.aidevops/agents/scripts/context-builder-helper.sh compress [path]

# Full pack with smart defaults
~/.aidevops/agents/scripts/context-builder-helper.sh pack [path] [xml|markdown|json]

# Quick mode - auto-copies to clipboard
~/.aidevops/agents/scripts/context-builder-helper.sh quick [path] [pattern]

# Analyze token usage per file
~/.aidevops/agents/scripts/context-builder-helper.sh analyze [path] [threshold]

# Pack remote GitHub repo
~/.aidevops/agents/scripts/context-builder-helper.sh remote user/repo [branch]

# Compare full vs compressed
~/.aidevops/agents/scripts/context-builder-helper.sh compare [path]
```

**Direct CLI Commands** (when helper unavailable):

```bash
# Pack local directory with compression
npx repomix@latest . --compress --output context.xml

# Pack remote repository
npx repomix@latest --remote user/repo --compress --output context.xml

# Pack with specific patterns
npx repomix@latest . --include "src/**/*.ts" --ignore "**/*.test.ts"

# Analyze token usage
npx repomix@latest . --token-count-tree 100

# Output to stdout (pipe to clipboard or other tools)
npx repomix@latest . --stdout | pbcopy
```

**When to Use**:

| Scenario | Command | Token Impact |
|----------|---------|--------------|
| Share full codebase with AI | `pack` or `npx repomix .` | Full tokens |
| Architecture understanding | `compress` or `npx repomix . --compress` | ~80% reduction |
| Quick file subset | `quick . "**/*.ts"` | Minimal |
| External repo analysis | `remote user/repo` or `npx repomix --remote user/repo` | Compressed |

**Code Maps (compress mode)** extracts class/function signatures, interface definitions, import/export statements. Omits implementation details, comments, empty lines.

**Token Budget**:

| Context Size | Mode | Typical Use |
|--------------|------|-------------|
| < 10k tokens | `pack` | Small projects, specific files |
| 10-50k tokens | `compress` | Medium projects |
| 50k+ tokens | `compress` + patterns | Large projects, selective |

## CRITICAL: Remote Repository Guardrails

**NEVER blindly pack a remote repository.** Follow this escalation:

1. **Fetch README first** - `gh api repos/{owner}/{repo}/readme --jq '.content' | base64 -d` (~1-5K tokens)
2. **Check repo size** - `gh api repos/{user}/{repo} --jq '.size'` (size in KB)
3. **Apply size thresholds**:

| Repo Size (KB) | Est. Tokens | Action |
|----------------|-------------|--------|
| < 500 | < 50K | Safe for compressed pack |
| 500-2000 | 50-200K | Use `--include` patterns only |
| > 2000 | > 200K | **NEVER full pack** - targeted files only |

4. **Use patterns**:

```bash
npx repomix@latest --remote user/repo --include "README.md,src/**/*.ts,docs/**" --compress
```

**What NOT to do:**

```bash
# DANGEROUS - packs entire repo without size check
npx repomix@latest --remote https://github.com/some/large-repo
```

See `tools/context/context-guardrails.md` for full workflow and recovery procedures.

<!-- AI-CONTEXT-END -->

## Usage Examples

### 1. Compress Mode (Recommended)

Extract code structure with ~80% token reduction:

```bash
./context-builder-helper.sh compress                          # current directory
./context-builder-helper.sh compress ~/projects/myapp        # specific project
./context-builder-helper.sh compress ~/projects/myapp markdown
```

Compress extracts signatures only — implementation bodies are omitted:

```typescript
// Compressed output (structure only)
export class UserService {
  private db: Database;
  constructor(db: Database);
  async getUser(id: string): Promise<User | null>;
  private mapToUser(row: any): User;
}
```

### 2. Full Pack Mode

When you need complete implementation details:

```bash
./context-builder-helper.sh pack                  # XML (default, best for Claude)
./context-builder-helper.sh pack . markdown
./context-builder-helper.sh pack . json
```

### 3. Quick Mode

Fast, focused context with auto-clipboard:

```bash
./context-builder-helper.sh quick . "**/*.ts"
./context-builder-helper.sh quick src/components "**/*.tsx"
```

### 4. Token Analysis

```bash
./context-builder-helper.sh analyze              # files with 100+ tokens
./context-builder-helper.sh analyze . 50         # lower threshold
./context-builder-helper.sh analyze ~/Git/aidevops 100
```

### 5. Remote Repository

```bash
./context-builder-helper.sh remote facebook/react
./context-builder-helper.sh remote vercel/next.js canary
./context-builder-helper.sh remote sveltejs/svelte main markdown
```

### 6. Compare Full vs Compressed

```bash
./context-builder-helper.sh compare ~/projects/myapp
```

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
```

## Output Files

All output saved to `~/.aidevops/.agent-workspace/work/context/`:

```text
~/.aidevops/.agent-workspace/work/context/
├── aidevops-full-20250129-143022.xml
├── aidevops-compressed-20250129-143045.xml
├── react-remote-20250129-150000.xml
└── myapp-quick-20250129-151030.md
```

File naming: `{repo-name}-{mode}-{timestamp}.{format}`

## Effective Patterns

```bash
# Large projects: combine compression with patterns
./context-builder-helper.sh compress . --include "src/**/*.ts"

# Monorepos: target specific packages
./context-builder-helper.sh compress packages/core

# Debugging: pack only relevant directories
./context-builder-helper.sh pack src/services markdown
```

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

**"npx not found"** — install Node.js: `brew install node`

**"Permission denied"** — `chmod +x ~/.aidevops/agents/scripts/context-builder-helper.sh`

**Large output file** — use compression or filter:

```bash
./context-builder-helper.sh compress
./context-builder-helper.sh pack . --include "src/**/*.ts" --ignore "**/*.test.ts"
```

## Integration

Use the `@context-builder` subagent or call the helper directly:

```text
@context-builder compress ~/projects/myapp
```

Manual workflow:

1. Generate: `./context-builder-helper.sh compress .`
2. Copy: `cat ~/.aidevops/.agent-workspace/work/context/myapp-*.xml | pbcopy`
3. Paste into AI conversation with your question

**Note on MCP**: While Repomix supports MCP server mode (`npx repomix --mcp`), this framework uses the CLI directly for better control and reliability.

## Related

- [Repomix Documentation](https://repomix.com/guide/)
- [RepoPrompt Concepts](https://repoprompt.com/docs)
- [aidevops Framework](~/Git/aidevops/AGENTS.md)
