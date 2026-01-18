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

- **Purpose**: Prevent context overload from large operations
- **Budget**: Reserve 100K tokens for conversation; never use >100K on context
- **Key Rule**: README first, check size, use patterns

**Size Thresholds**:

| Repo Size (KB) | Est. Tokens | Action |
|----------------|-------------|--------|
| < 500 | < 50K | Safe for compressed pack |
| 500-2000 | 50-200K | Use `includePatterns` only |
| > 2000 | > 200K | **NEVER full pack** - targeted files only |

**Self-check before context-heavy operations**:
> "Could this operation return >50K tokens? Have I checked the size first?"

<!-- AI-CONTEXT-END -->

## The Problem

Claude's context window is 200K tokens. Context-heavy operations can easily exceed this:

| Tool | Typical Output | Risk Level |
|------|----------------|------------|
| `repomix_pack_remote_repository` | 100K - 5M+ tokens | **EXTREME** |
| `mcp_grep` on large output | 10K - 500K tokens | **HIGH** |
| `webfetch` on docs site | 5K - 50K tokens | Medium |
| `mcp_read` single file | 1K - 20K tokens | Low |

## Golden Rules

1. **Budget**: Reserve 100K tokens for conversation. Never use >100K on context.
2. **Escalate gradually**: README -> specific files -> targeted patterns -> full pack (last resort)
3. **Pre-flight checks**: Always check size before packing remote repos
4. **Post-check output**: If grep/search returns >500 lines, DON'T load it all

## Remote Repository Research Workflow

```text
START
  |
  v
+-------------------------------------+
| 1. Fetch README via webfetch        |  ~1-5K tokens
|    (Understand purpose & structure) |
+-------------------------------------+
  |
  v
+-------------------------------------+
| 2. Check repo size                  |
|    gh api repos/{u}/{r} --jq .size  |
+-------------------------------------+
  |
  +-- < 500 KB --> Safe for compressed pack
  |
  +-- 500KB-2MB --> Use includePatterns only
  |
  +-- > 2MB --> STOP - targeted files only
```

## Size Estimation

GitHub API `.size` is in KB. Rough token estimate:

- **Repo KB x 10 = approximate full-pack tokens** (very rough)
- **Compressed mode reduces by ~80%**
- **Targeted patterns can reduce by 90-99%**

## Tool-Specific Guardrails

### repomix_pack_remote_repository

```bash
# BAD - no size check, no patterns
repomix_pack_remote_repository("https://github.com/large/repo")

# GOOD - size check first
gh api repos/large/repo --jq '.size'  # Check KB
# If < 500 KB:
repomix_pack_remote_repository("https://github.com/small/repo", compress=true)
# If > 500 KB:
repomix_pack_remote_repository("https://github.com/large/repo", includePatterns="README.md,src/**/*.ts,docs/**")
```

### mcp_grep on large outputs

```bash
# BAD - grepping on potentially huge output
mcp_repomix_grep_repomix_output(outputId="...", pattern="install")

# GOOD - limit context lines, be specific
mcp_repomix_grep_repomix_output(outputId="...", pattern="^## Install", contextLines=5)
# Or read specific line ranges after finding matches
mcp_repomix_read_repomix_output(outputId="...", startLine=100, endLine=200)
```

### webfetch on documentation sites

```bash
# CAUTION - docs sites can be large
webfetch("https://docs.example.com/")  # May return 50K+ tokens

# BETTER - target specific pages
webfetch("https://docs.example.com/getting-started")
webfetch("https://raw.githubusercontent.com/user/repo/main/README.md")
```

## Recovery from Context Overflow

If you hit "prompt is too long":

1. **Start a new conversation** - Context cannot be reduced mid-session
2. **Ask user what specific question they have** - Focus on the actual need
3. **Use targeted approach** - Get only needed context
4. **Document the failure** - Use `/remember` for future sessions:
   ```
   /remember FAILED_APPROACH: Attempted to pack {repo} without size check. 
   Repo was {size}KB (~{tokens} tokens). Use includePatterns next time.
   ```

## File Discovery Guardrails

Before using `mcp_glob`, check if faster alternatives work:

| Use Case | Preferred Tool | Fallback |
|----------|---------------|----------|
| Git-tracked files | `git ls-files '*.md'` | `mcp_glob` |
| Untracked files | `fd -e md` | `mcp_glob` |
| System-wide search | `fd -g '*.md' ~/.config/` | `mcp_glob` |

**Why?** `mcp_glob` is CPU-intensive on large codebases. CLI tools are 10x faster.

## Agent Capability Check

Before attempting edits, verify you have the required tools:

```text
Self-check: "Do I have Edit/Write/Bash tools for this task?"

If NO (e.g., in Plan+ agent):
  -> Suggest: "This task requires edits. Please switch to Build+ agent."

If YES:
  -> Proceed with pre-edit git check
```

## Integration with Other Guardrails

This document complements:

- **Pre-Edit Git Check** (AGENTS.md) - Branch safety before edits
- **File Discovery** (AGENTS.md) - Tool selection for file operations
- **Context Builder** (context-builder.md) - Token-efficient context generation

## Related Documentation

- `tools/context/context-builder.md` - Repomix wrapper for context generation
- `tools/context/context7.md` - External library documentation
- `tools/build-agent/build-agent.md` - Agent design principles
