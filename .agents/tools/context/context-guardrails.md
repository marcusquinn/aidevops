---
description: Context budget management and guardrails for AI assistants
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
---

# Context Guardrails

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Budget**: Reserve 100K tokens for conversation; never use >100K on context
- **Rule**: README first → check size → targeted patterns → full pack (last resort)
- **Self-check**: "Could this return >50K tokens? Have I checked size first?"

**Size Thresholds**:

| Repo Size (KB) | Est. Tokens | Action |
|----------------|-------------|--------|
| < 500 | < 50K | Safe for compressed pack |
| 500-2000 | 50-200K | `--include` patterns only |
| > 2000 | > 200K | **NEVER full pack** - targeted files only |

**Tool risk**:

| Tool | Typical Output | Risk |
|------|----------------|------|
| `npx repomix --remote` | 100K-5M+ tokens | **EXTREME** |
| `mcp_grep` on large output | 10K-500K tokens | **HIGH** |
| `webfetch` on docs site | 5K-50K tokens | Medium |
| `mcp_read` single file | 1K-20K tokens | Low |

<!-- AI-CONTEXT-END -->

## Remote Repository Research Workflow

Check size before packing. `gh api repos/{u}/{r} --jq .size` returns KB.

| Size | Action |
|------|--------|
| < 500 KB | `npx repomix@latest --remote ... --compress` |
| 500 KB-2 MB | Add `--include "README.md,src/**/*.ts,docs/**"` |
| > 2 MB | Targeted files only - no full pack |

**Token estimate**: Repo KB x 100 = approximate full-pack tokens. Compressed mode reduces ~70-80%; targeted patterns reduce 90-99%.

```bash
gh api repos/owner/repo --jq '.size'

# < 500 KB:
npx repomix@latest --remote https://github.com/small/repo --compress

# > 500 KB:
npx repomix@latest --remote https://github.com/large/repo \
  --include "README.md,src/**/*.ts,docs/**" --compress

# Or use the helper (auto-compresses):
~/.aidevops/agents/scripts/context-builder-helper.sh remote large/repo main
```

## Tool-Specific Guardrails

### webfetch on documentation sites

```bash
# AVOID - docs sites can return 50K+ tokens
webfetch("https://docs.example.com/")

# PREFER - Context7 MCP for library docs (curated, no URL guessing)
# resolve-library-id -> get-library-docs

# PREFER - gh api for GitHub content (handles auth, structured JSON)
gh api repos/{owner}/{repo}/readme --jq '.content' | base64 -d

# AVOID - raw.githubusercontent.com has 70% failure rate (agents guess wrong paths)
```

### Searching packed output

```bash
grep -n "install" context.xml
grep -B2 -A5 "## Install" context.xml
sed -n '100,200p' context.xml
```

## Recovery from Context Overflow

If you hit "prompt is too long":

1. **Start a new conversation** - context cannot be reduced mid-session
2. **Focus on the actual need** - ask what specific question the user has
3. **Use targeted approach** - get only needed context
4. **Document the failure** for future sessions:

   ```text
   /remember FAILED_APPROACH: Attempted to pack {repo} without size check.
   Repo was {size}KB (~{tokens} tokens). Use --include patterns next time.
   ```

## File Discovery Guardrails

Prefer CLI tools over `mcp_glob` - 10x faster on large codebases.

| Use Case | Preferred | Fallback |
|----------|-----------|----------|
| Git-tracked files | `git ls-files '<pattern>'` | `mcp_glob` |
| Untracked files | `fd -e <ext>` or `fd -g '<pattern>'` | `mcp_glob` |
| System-wide search | `fd -g '<pattern>' <dir>` | `mcp_glob` |
| Text file contents | `rg 'pattern'` | `mcp_grep` |
| PDFs/DOCX/zips | `rga 'pattern'` | None |

`fd` = files by name/metadata. `rg` = text contents. `rga` (ripgrep-all) = non-text files (PDF, DOCX, SQLite, archives).

## Agent Capability Check

Before edits: confirm you have Edit/Write/Bash tools. If not (e.g., read-only subagent), suggest switching to Build+ agent, then proceed with the pre-edit git check.

## Related

- `tools/context/context-builder.md` - repomix wrapper for context generation
- `tools/context/context7.md` - external library documentation
- `tools/build-agent/build-agent.md` - agent design principles
- **Pre-Edit Git Check** (AGENTS.md) - branch safety before edits
- **File Discovery** (AGENTS.md) - tool selection for file operations
