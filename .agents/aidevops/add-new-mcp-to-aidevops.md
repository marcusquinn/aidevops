---
description: Guide for adding new MCP integrations
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Adding New MCP Integrations to AI DevOps

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Standardized process for adding new MCP server integrations
- **Output Files**: Documentation, config templates, setup script updates
- **Supported AI Assistants**: OpenCode, Cursor, Claude Code/Desktop, Gemini CLI, Windsurf, Continue.dev, Cody, Zed, GitHub Copilot, Kilo Code, Kiro, Droid (Factory.AI), Warp AI, Aider, Qwen

**Steps**: (1) Research MCP, (2) Determine agent enablement, (3) Create `.agents/tools/{category}/{mcp-name}.md`, (4) Create config templates, (5) Update `generate-opencode-agents.sh`, (6) Update `ai-cli-config.sh`, (7) Update `setup.sh` if needed, (8) Run quality checks, (9) Test with verification prompt.

**MCP Tool Enablement Strategy**:

- **Global Config**: Disabled (`"enabled": false` in opencode.json)
- **Subagent Only**: Enable `mcp-name_*: true` in the subagent's `tools:` section
- **Never in Main Agents**: Main agents reference subagents but never enable MCPs directly
- **Rationale**: Context efficiency — MCP only loads when subagent is invoked

```yaml
# In services/crm/fluentcrm.md (SUBAGENT) - CORRECT
tools:
  fluentcrm_*: true

# In marketing-sales.md (MAIN AGENT) - NO MCP tools here
tools:
  read: true
```

**Related Agents**: `@Build-Agent` (structure), `@agent-review` (doc quality), `@best-practices` (code quality), `@secretlint` (credential check)

<!-- AI-CONTEXT-END -->

## Step 1: Research the MCP

Gather before starting — use WebFetch for official setup guides per AI tool:

| Item | Example |
|------|---------|
| Official docs URL | `https://docs.example.com/mcp/overview` |
| Install command | `npm install -g @example/mcp@latest` |
| Auth method | CLI login, API key, OAuth |
| Credentials location | `~/.example/session.json` |
| MCP tool names | `codebase-retrieval`, `search-docs` |
| Prerequisites | Node.js 22+, Python 3.8+ |

```bash
npm view @example/mcp --json | head -50
command -v example-cli
npm docs @example/mcp
# Version check — MCP methods change between versions; outdated commands cause "Connection closed" errors
npm view {package} version  # Latest available
{tool} --version            # Currently installed
npm update -g {package}     # Update if outdated
```

## Step 2: Determine Agent Enablement

Ask the user which agents need this MCP:

> "Which agents should have `{mcp-name}_*: true`?
> Available: Build+, Accounts, AI-DevOps, Content, Health, Legal, Marketing, Research, Sales, SEO, WordPress
> Common patterns: codebase/context tools → Build+, AI-DevOps, Research; domain-specific → relevant domain only"

## Step 3: Create Documentation File

Create `.agents/tools/{category}/{mcp-name}.md`. Use `.agents/tools/context/augment-context-engine.md` as reference template.

**Categories**: `context/`, `code-review/`, `deployment/`, `browser/`, `git/`, `credentials/`, `ai-assistants/`.

**Required sections**: AI-CONTEXT-START block (purpose, install, auth, tool names, docs URL, config snippet, verification prompt, supported assistants, enabled agents), What It Does, Prerequisites, Installation, AI Assistant Configurations (one per assistant), Verification, Non-Interactive Setup, Troubleshooting, Updates.

## Step 4: Create Config Templates

- `configs/{mcp-name}-config.json.txt` — comprehensive JSON template for all AI assistants
- `configs/mcp-templates/{mcp-name}.json` — quick-reference snippets organized by tool

## Step 5: Update generate-opencode-agents.sh

Add MCP only to agents from Step 2:

```python
"Build+": {
    "tools": {
        # ... existing tools ...
        "{mcp-name}_*": True  # Only if enabled for this agent
    }
},
```

## Step 6: Update ai-cli-config.sh

```bash
configure_{mcp_name}_mcp() {
    log_info "Configuring {MCP Name} for AI assistants..."
    if ! command -v {cli} >/dev/null 2>&1; then
        log_warning "{CLI} not found - skipping"
        log_info "Install with: {install command}"
        return 0
    fi
    # Configure each detected assistant
    log_success "{MCP Name} configured for detected AI assistants"
    return 0
}
```

**Config locations by assistant**:

| Assistant | Config Location | Method |
|-----------|-----------------|--------|
| OpenCode | `~/.config/opencode/opencode.json` | JSON merge |
| Cursor | `~/.cursor/mcp.json` | JSON merge |
| Claude Code | Via `claude mcp add-json` | CLI |
| Windsurf | `~/.codeium/windsurf/` | JSON merge |
| Continue.dev | `~/.continue/` | JSON merge |
| Cody | `~/.cody/` | JSON merge |
| Gemini CLI | `~/.gemini/settings.json` | JSON merge |
| Droid | Via `droid mcp add` | CLI |
| Zed | Custom server UI | Document only |
| GitHub Copilot | `.vscode/mcp.json` | Per-project |
| Kilo/Kiro | Global MCP config | JSON merge |

## Step 7: Update setup.sh (If Prerequisites Needed)

Add setup function if the MCP has prerequisites to validate.

## Step 8: Run Quality Checks

```bash
shellcheck .agents/scripts/ai-cli-config.sh
shellcheck setup.sh
npx markdownlint-cli .agents/tools/{category}/{mcp-name}.md
.agents/scripts/linters-local.sh
.agents/scripts/secretlint-helper.sh check
```

## Step 9: Test the Integration

```bash
# Test OpenCode agent generation
bash .agents/scripts/generate-opencode-agents.sh

# Verify MCP in config
cat ~/.config/opencode/opencode.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('MCP in config:', '{mcp-name}' in d.get('mcp',{}))
for agent, cfg in d.get('agent',{}).items():
    if cfg.get('tools',{}).get('{mcp-name}_*'):
        print(f'  - {agent}')
"

# Test MCP accessibility (no restart required)
~/.aidevops/agents/scripts/opencode-test-helper.sh test-mcp {mcp-name} Build+
```

Restart OpenCode TUI for interactive verification after CLI tests pass.
After implementation: `@agent-review Review the new {mcp-name} documentation and configuration`

## Completion Checklist

- [ ] Documentation follows template structure (all AI assistants covered)
- [ ] Config template (`configs/`) and MCP snippets file created
- [ ] `generate-opencode-agents.sh` updated for selected agents only
- [ ] `ai-cli-config.sh` has configure function for all assistants
- [ ] `setup.sh` updated if prerequisites needed
- [ ] ShellCheck, markdown linting, secretlint all pass
- [ ] Verification prompt tested in at least OpenCode
- [ ] No hardcoded credentials; links to official docs included
- [ ] Agent review completed

## Common Patterns

**MCP config formats by assistant**:

| Assistant | Format | Key Differences |
|-----------|--------|-----------------|
| OpenCode | `"type": "local"` | Has `enabled` flag, tools disabled globally |
| Claude Code | `"type": "stdio"` | Added via CLI, scope: user/project |
| Cursor | No type field | Uses `${WORKSPACE_FOLDER_PATHS}` |
| Windsurf | Similar to Cursor | Check `.codeium/` directory |
| Continue.dev | Check `.continue/` | May vary by version |
| Gemini CLI | No type field | User or project level |
| Droid | CLI-based | `droid mcp add` command |

**Workspace path handling**:

```json
// Cursor/Windsurf (macOS/Linux)
"args": ["-c", "cmd --mcp -w \"${WORKSPACE_FOLDER_PATHS%%,*}\""]
// Cursor/Windsurf (Windows)
"args": ["-Command", "cmd --mcp -w \"($env:WORKSPACE_FOLDER_PATHS -split ',')[0]\""]
// Zed
"args": ["-c", "cmd --mcp -w $(pwd)"]
// Generic
"args": ["--mcp", "-w", "/path/to/project"]
```

## Reference Implementation

See Augment Context Engine for patterns — search `augment-context-engine` in:

| File | Purpose |
|------|---------|
| `.agents/tools/context/augment-context-engine.md` | Documentation |
| `configs/augment-context-engine-config.json.txt` | Config template |
| `configs/mcp-templates/augment-context-engine.json` | MCP snippets |
| `.agents/scripts/generate-opencode-agents.sh` | Agent config |
| `.agents/scripts/ai-cli-config.sh` | CLI config function |
| `setup.sh` | Setup function |
