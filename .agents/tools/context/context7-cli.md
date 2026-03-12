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

- **Purpose**: Query Context7 library docs and skills over CLI when MCP is unavailable or when compact JSON output is preferred
- **Install/Setup**: `npx ctx7 setup --opencode --cli`
- **Core commands**:
  - `npx ctx7 library <name> [query] --json`
  - `npx ctx7 docs <libraryId> <query> --json`
  - `npx ctx7 skills search <query>`
- **Best use cases**:
  - MCP transport is unavailable, disabled, or rate-limited
  - You need quick shell-native docs lookups inside scripts/workflows
  - You want JSON output for deterministic post-processing
- **Telemetry**: disable with `export CTX7_TELEMETRY_DISABLED=1`

**Lookup pattern**:

1. Resolve library ID with `ctx7 library`
2. Query docs with `ctx7 docs`
3. Only fall back to web docs if Context7 has no coverage

<!-- AI-CONTEXT-END -->

## Usage

### 1) Resolve a library ID

```bash
npx -y ctx7 library react --json
```

### 2) Query focused docs

```bash
npx -y ctx7 docs /facebook/react "useEffect examples" --json
```

### 3) One-shot lookup from name + question

```bash
LIB_ID=$(npx -y ctx7 library react --json | jq -r '.library.id // empty')
if [ -n "$LIB_ID" ]; then
  npx -y ctx7 docs "$LIB_ID" "how to memoize expensive renders" --json
else
  echo "Error: Library 'react' not found." >&2
fi
```

## Backend Selection Guidance

- Prefer `@context7` (MCP) for normal interactive coding flows
- Prefer `@context7-cli` for shell-first workflows, scripting, and MCP fallback
- Keep downstream prompts backend-agnostic by passing normalized outputs (library ID + doc snippet)

## Verification

Run:

```text
@context7-cli Find the React library ID and return docs for useEffect dependency arrays.
```

Expected result: a valid Context7 library ID and relevant documentation excerpts returned via CLI calls.
