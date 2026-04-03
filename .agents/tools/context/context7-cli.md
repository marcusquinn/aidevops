---
description: Context7 CLI lookups for library docs and skills without MCP
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Context7 CLI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Use Context7 over CLI when MCP is unavailable or JSON output is easier to post-process
- **Setup**: `npx ctx7 setup --opencode --cli`
- **Commands**: `npx ctx7 library <name> [query] --json` · `npx ctx7 docs <libraryId> <query> --json` · `npx ctx7 skills search <query>`
- **Use when**: MCP is unavailable/rate-limited, shell scripts need docs lookups, or downstream tooling expects JSON
- **Order**: resolve library ID with `ctx7 library` → query docs with `ctx7 docs` → only fall back to web docs if Context7 has no coverage
- **Telemetry**: `export CTX7_TELEMETRY_DISABLED=1`
- **Backend**: prefer `@context7` for interactive flows; `@context7-cli` for shell/scripting/MCP fallback; pass normalized outputs (library ID + doc snippet) to keep prompts backend-agnostic
- **Verify**: `@context7-cli Find the React library ID and return docs for useEffect dependency arrays.` → expect valid library ID + doc excerpts

<!-- AI-CONTEXT-END -->

## Usage

```bash
# One-shot lookup: resolve library ID then query docs (with error handling)
LIB_ID=$(npx -y ctx7 library react --json | jq -r '.library.id // empty')
[ -n "$LIB_ID" ] && npx -y ctx7 docs "$LIB_ID" "how to memoize expensive renders" --json \
  || echo "Error: Library 'react' not found." >&2
```
