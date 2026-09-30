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
- **Escalate gradually**: README → specific files → targeted patterns → bulk load (last resort)
- **Pre-flight**: Always check repo size before bulk loading; if grep/search returns >500 lines, don't load it all

**Size Thresholds** — `gh api repos/{u}/{r} --jq .size` returns KB; KB × 100 ≈ full-load tokens:

| Repo Size (KB) | Est. Tokens | Action |
|----------------|-------------|--------|
| < 500 | < 50K | Load selected directories only |
| 500-2000 | 50-200K | Targeted paths only |
| > 2000 | > 200K | **NEVER bulk load** — targeted files only |

**Tool risk**:

| Tool | Typical Output | Risk |
|------|----------------|------|
| Bulk-loading a remote repo | 100K–5M+ tokens | **EXTREME** |
| `mcp_grep` on large output | 10K–500K tokens | **HIGH** |
| `webfetch` on docs site | 5K–50K tokens | Medium |
| `mcp_read` single file | 1K–20K tokens | Low |

**Self-check before context-heavy operations**:
> "Could this operation return >50K tokens? Have I checked the size first?"

<!-- AI-CONTEXT-END -->

## Tool-Specific Guardrails

### Whole-repository ingestion

```bash
# BAD - bulk-loading a remote repo with no size check
# GOOD - check size first, list the tree, then fetch only needed files
gh api repos/owner/repo --jq '.size'
gh api "repos/owner/repo/git/trees/main?recursive=1" --jq '.tree[].path'
gh api repos/owner/repo/contents/README.md --jq '.content' | base64 -d
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

## Recovery from Context Overflow

If you hit "prompt is too long":

1. **Start a new conversation** — context cannot be reduced mid-session
2. **Ask user what specific question they have** — focus on the actual need
3. **Use targeted approach** — get only needed context
4. **Document the failure** — use `/remember` for future sessions:

   ```text
   /remember FAILED_APPROACH: Attempted to bulk-load {repo} without size check.
   Repo was {size}KB (~{tokens} tokens). Fetch targeted paths next time.
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

- `tools/context/context7.md` — external library documentation
- `tools/build-agent/build-agent.md` — agent design principles
