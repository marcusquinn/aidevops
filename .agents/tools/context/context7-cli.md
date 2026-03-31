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

<!-- AI-CONTEXT-END -->

## Usage

### Resolve a library ID

```bash
npx -y ctx7 library react --json
```

### Query focused docs

```bash
npx -y ctx7 docs /facebook/react "useEffect examples" --json
```

### One-shot lookup from name + question

```bash
LIB_ID=$(npx -y ctx7 library react --json | jq -r '.library.id // empty')
if [ -n "$LIB_ID" ]; then
  npx -y ctx7 docs "$LIB_ID" "how to memoize expensive renders" --json
else
  echo "Error: Library 'react' not found." >&2
fi
```

## Backend Selection Guidance

- Prefer `@context7` for normal interactive coding flows
- Prefer `@context7-cli` for shell-first workflows, scripting, and MCP fallback
- Keep downstream prompts backend-agnostic by passing normalized outputs (library ID + doc snippet)

## Verification

```text
@context7-cli Find the React library ID and return docs for useEffect dependency arrays.
```

Expected: a valid Context7 library ID plus relevant documentation excerpts returned via CLI calls.
