---
description: Context budget management and guardrails for AI assistants
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Context Guardrails

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Budget**: Reserve 100K tokens for conversation; never use >100K on context
- **Escalate gradually**: README → specific files → targeted patterns → full pack (last resort)
- **Pre-flight**: Always check repo size before packing; if grep/search returns >500 lines, don't load it all

**Size Thresholds** — `gh api repos/{u}/{r} --jq .size` returns KB; KB × 100 ≈ full-pack tokens:

| Repo Size (KB) | Est. Tokens | Action |
|----------------|-------------|--------|
| < 500 | < 50K | Safe for compressed pack |
| 500-2000 | 50-200K | Use `--include` patterns only |
| > 2000 | > 200K | **NEVER full pack** — targeted files only |

**Tool risk**:

| Tool | Typical Output | Risk |
|------|----------------|------|
| `npx repomix --remote` | 100K–5M+ tokens | **EXTREME** |
| `mcp_grep` on large output | 10K–500K tokens | **HIGH** |
| `webfetch` on docs site | 5K–50K tokens | Medium |
| `mcp_read` single file | 1K–20K tokens | Low |

**Self-check before context-heavy operations**:
> "Could this operation return >50K tokens? Have I checked the size first?"

<!-- AI-CONTEXT-END -->

## Tool-Specific Guardrails

### npx repomix --remote

```bash
# BAD - no size check, no patterns
npx repomix@latest --remote https://github.com/large/repo

# GOOD - check size first, then compress
gh api repos/owner/repo --jq '.size'

# < 500 KB:
npx repomix@latest --remote https://github.com/small/repo --compress

# > 500 KB:
npx repomix@latest --remote https://github.com/large/repo \
  --include "README.md,src/**/*.ts,docs/**" --compress

# Or use the helper (auto-compresses):
~/.aidevops/agents/scripts/context-builder-helper.sh remote large/repo main
```

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

1. **Start a new conversation** — context cannot be reduced mid-session
2. **Ask user what specific question they have** — focus on the actual need
3. **Use targeted approach** — get only needed context
4. **Document the failure** — use `/remember` for future sessions:

   ```text
   /remember FAILED_APPROACH: Attempted to pack {repo} without size check.
   Repo was {size}KB (~{tokens} tokens). Use --include patterns next time.
   ```

## File Discovery Guardrails

| Use Case | Preferred | Fallback |
|----------|-----------|----------|
| Git-tracked files | `git ls-files '<pattern>'` | `mcp_glob` |
| Untracked files | `fd -e <ext>` or `fd -g '<pattern>'` | `mcp_glob` |
| System-wide search | `fd -g '<pattern>' <dir>` | `mcp_glob` |
| Search text file contents | `rg 'pattern'` | `mcp_grep` |
| Search inside PDFs/DOCX/zips | `rga 'pattern'` | None (unique capability) |

`mcp_glob` is CPU-intensive on large codebases; CLI tools are 10× faster. `fd` finds files by name/metadata, `rg` searches text contents, `rga` searches inside non-text files (PDF, DOCX, SQLite, archives) — same syntax as `rg`.

## Agent Capability Check

Before attempting edits: "Do I have Edit/Write/Bash tools for this task?" If not (e.g., read-only mode), suggest switching to Build+ agent. If yes, proceed with pre-edit git check.

## Related

- `tools/context/context-builder.md` — repomix wrapper for context generation
- `tools/context/context7.md` — external library documentation
- `tools/build-agent/build-agent.md` — agent design principles
