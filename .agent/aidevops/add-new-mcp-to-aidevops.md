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

# Adding New MCP Integrations to AI DevOps

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Standardized process for adding new MCP server integrations
- **Output Files**: Documentation, config templates, setup script updates
- **Coverage**: All supported AI assistants (see list below)

**Supported AI Assistants** (configure MCP for each):

- OpenCode, Cursor, Claude Code/Desktop, Gemini CLI
- Windsurf, Continue.dev, Cody, Zed
- GitHub Copilot, Kilo Code, Kiro, AntiGravity
- Droid (Factory.AI), Warp AI, Aider, Qwen

**Checklist**:

1. Research MCP (official docs, npm/pip package, GitHub)
2. Create `.agent/tools/{category}/{mcp-name}.md` documentation
3. Create `configs/{mcp-name}-config.json.txt` template
4. Create `configs/mcp-templates/{mcp-name}.json` snippets
5. Update `.agent/scripts/generate-opencode-agents.sh` (add to selected agents)
6. Update `.agent/scripts/ai-cli-config.sh` (add configure function)
7. Update `setup.sh` (add setup function if prerequisites needed)
8. Run quality checks and linters
9. Test with verification prompt

**MCP Tool Enablement Strategy**:

- **Global**: Disabled (`"mcp-name_*": false` in tools section)
- **Per-Agent**: Enabled only for agents that need it
- **Rationale**: Context efficiency - each agent only loads needed MCPs

**Related Agents to Call**:

- `@Build-Agent` - Design guidance for agent/subagent structure
- `@agent-review` - Review new documentation quality
- `@best-practices` - Code quality standards
- `@secretlint` - Check for credential leaks before commit

<!-- AI-CONTEXT-END -->

## Overview

This guide ensures consistent, comprehensive MCP integration across the aidevops
framework. Follow this process for any new MCP server to maintain quality and
coverage across all supported AI assistants.

## Pre-Implementation: Call Related Agents

Before starting, consider calling these agents:

```text
@Build-Agent - Should this MCP have its own subagent? Which agents need it?
@architecture - Does this fit the current framework structure?
```

## Step 1: Research the MCP

Before implementation, gather all necessary information.

### Required Information

| Item | Description | Example |
|------|-------------|---------|
| **Official docs URL** | Primary documentation source | `https://docs.example.com/mcp/overview` |
| **Install command** | npm/pip/binary installation | `npm install -g @example/mcp@latest` |
| **Auth method** | How users authenticate | CLI login, API key, OAuth |
| **Credentials location** | Where auth is stored | `~/.example/session.json` |
| **MCP tool names** | Tools exposed by the MCP | `codebase-retrieval`, `search-docs` |
| **Prerequisites** | Required dependencies | Node.js 22+, Python 3.8+ |
| **Supported AI tools** | Which tools have official docs | OpenCode, Cursor, Claude Code, etc. |

### Research Commands

```bash
# Check npm package details
npm view @example/mcp --json | head -50

# Check if already installed
command -v example-cli

# Check package documentation
npm docs @example/mcp
```

### Fetch Official Documentation

Use WebFetch to gather official setup guides for each AI tool the MCP supports.

## Step 2: Determine Agent Enablement

**Critical Decision**: Which agents should have this MCP enabled?

### Ask the User

Before proceeding, ask:

> "Which main agents and subagents should have this MCP enabled?
>
> **Main Agents Available**:
> Plan+, Build+, Accounting, AI-DevOps, Content, Health, Legal, Marketing,
> Research, Sales, SEO, WordPress
>
> **Recommendation**: Enable globally disabled, then enable per-agent only
> where needed for context efficiency.
>
> **Common patterns**:
> - Codebase/context tools → Plan+, Build+, AI-DevOps, WordPress, Research
> - Documentation tools → All development agents
> - Domain-specific → Only relevant domain agents
>
> Which agents should have `{mcp-name}_*: true`?"

### Document the Decision

Record which agents and why:

```markdown
## Agent Enablement

| Agent | Enabled | Rationale |
|-------|---------|-----------|
| Plan+ | Yes | Needs codebase context for planning |
| Build+ | Yes | Primary development agent |
| AI-DevOps | Yes | Infrastructure development |
| WordPress | No | Not relevant to WordPress tasks |
| ... | ... | ... |
```

## Step 3: Create Documentation File

Create `.agent/tools/{category}/{mcp-name}.md`:

### File Location Categories

| Category | Use For |
|----------|---------|
| `context/` | Codebase understanding, documentation lookup, context building |
| `code-review/` | Linting, security scanning, quality analysis |
| `deployment/` | CI/CD, hosting, infrastructure |
| `browser/` | Web automation, scraping, testing |
| `git/` | Version control, repository management |
| `credentials/` | Secret management, API keys |
| `ai-assistants/` | AI tool configuration, integration |

### Documentation Template

Use `.agent/tools/context/augment-context-engine.md` as a reference template.

**Required Sections**:

1. **AI-CONTEXT-START block** with Quick Reference:
   - Purpose, Install command, Auth command
   - MCP Tool names, Docs URL
   - OpenCode config JSON snippet
   - Verification prompt
   - Supported AI Assistants list
   - Enabled for Agents list

2. **What It Does** - Explain MCP benefits

3. **Prerequisites** - Dependencies and requirements

4. **Installation** - Step-by-step install and auth

5. **AI Assistant Configurations** - One section per assistant:
   - OpenCode, Claude Code, Cursor, Windsurf
   - Continue.dev, Cody, Zed, GitHub Copilot
   - Kilo Code, Kiro, AntiGravity, Gemini CLI
   - Droid (Factory.AI), Warp AI, Aider, Qwen

6. **Verification** - Test prompt and expected results

7. **Non-Interactive Setup (CI/CD)** - Environment variables

8. **Troubleshooting** - Common issues and solutions

9. **Updates** - Link to official docs for latest configs

## Step 4: Create Config Templates

### configs/{mcp-name}-config.json.txt

Comprehensive JSON template with all AI assistant configurations.

### configs/mcp-templates/{mcp-name}.json

Quick-reference snippets organized by tool.

## Step 5: Update generate-opencode-agents.sh

Edit `.agent/scripts/generate-opencode-agents.sh`:

### Add MCP to Selected Agents Only

Based on the agent enablement decision from Step 2:

```python
"Plan+": {
    "tools": {
        # ... existing tools ...
        "{mcp-name}_*": True  # Only if enabled for this agent
    }
},
"Build+": {
    "tools": {
        # ... existing tools ...
        "{mcp-name}_*": True  # Only if enabled for this agent
    }
},
# Add to other enabled agents...
```

**Important**: Do NOT add to agents where not needed - this keeps context lean.

## Step 6: Update ai-cli-config.sh

Edit `.agent/scripts/ai-cli-config.sh`:

### Add Configure Function

The function should configure all detected AI assistants:

```bash
configure_{mcp_name}_mcp() {
    log_info "Configuring {MCP Name} for AI assistants..."

    # Check prerequisites
    if ! command -v {cli} >/dev/null 2>&1; then
        log_warning "{CLI} not found - skipping"
        log_info "Install with: {install command}"
        return 0
    fi

    # Configure OpenCode
    # Configure Cursor
    # Configure Gemini CLI
    # Configure Claude Code (if installed)
    # Configure Windsurf (if installed)
    # Configure Continue.dev (if installed)
    # Configure Droid (if installed)
    # ... etc for all supported assistants

    log_success "{MCP Name} configured for detected AI assistants"
}
```

### AI Assistant Config Locations

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
| AntiGravity | `~/.gemini/antigravity/` | JSON merge |

## Step 7: Update setup.sh (If Prerequisites Needed)

Add setup function if the MCP has prerequisites to validate.

## Step 8: Run Quality Checks

**Before committing, run all quality checks:**

```bash
# ShellCheck for any modified shell scripts
shellcheck .agent/scripts/ai-cli-config.sh
shellcheck setup.sh

# Markdown linting
npx markdownlint-cli .agent/tools/{category}/{mcp-name}.md

# Comprehensive quality check
.agent/scripts/linters-local.sh

# Check for credential leaks
.agent/scripts/secretlint-helper.sh check
```

**Call the secretlint subagent:**

```text
@secretlint Check all new and modified files for credential leaks
```

## Step 9: Test the Integration

### Run Scripts

```bash
# Test OpenCode agent generation
bash .agent/scripts/generate-opencode-agents.sh

# Verify configuration
cat ~/.config/opencode/opencode.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('MCP in config:', '{mcp-name}' in d.get('mcp',{}))
print('Agents with access:')
for agent, cfg in d.get('agent',{}).items():
    if cfg.get('tools',{}).get('{mcp-name}_*'):
        print(f'  - {agent}')
"
```

### Test in OpenCode

1. Restart OpenCode
2. Switch to an enabled agent (Tab)
3. Run verification prompt
4. Confirm expected behavior

### Call Agent Review

After implementation:

```text
@agent-review Review the new {mcp-name} documentation and configuration
```

## Post-Implementation Checklist

- [ ] Documentation follows template structure
- [ ] All relevant AI assistants have configuration documented
- [ ] Config template includes all assistants
- [ ] MCP snippets file created
- [ ] generate-opencode-agents.sh updated for **selected agents only**
- [ ] ai-cli-config.sh has configure function for all assistants
- [ ] setup.sh updated if prerequisites needed
- [ ] ShellCheck passes on modified scripts
- [ ] Markdown linting passes
- [ ] Secretlint finds no credential leaks
- [ ] Verification prompt tested in at least OpenCode
- [ ] No hardcoded credentials in any file
- [ ] Links to official docs included
- [ ] Agent review completed

## Common Patterns

### MCP Config Formats by Assistant

| Assistant | Format | Key Differences |
|-----------|--------|-----------------|
| OpenCode | `"type": "local"` | Has `enabled` flag, tools disabled globally |
| Claude Code | `"type": "stdio"` | Added via CLI, scope: user/project |
| Cursor | No type field | Uses `${WORKSPACE_FOLDER_PATHS}` |
| Windsurf | Similar to Cursor | Check `.codeium/` directory |
| Continue.dev | Check `.continue/` | May vary by version |
| Gemini CLI | No type field | User or project level |
| Droid | CLI-based | `droid mcp add` command |

### Workspace Path Handling

```json
// Cursor/Windsurf (macOS/Linux)
"args": ["-c", "cmd --mcp -w \"${WORKSPACE_FOLDER_PATHS%%,*}\""]

// Cursor/Windsurf (Windows)
"args": ["-Command", "cmd --mcp -w \"($env:WORKSPACE_FOLDER_PATHS -split ',')[0]\""]

// Zed
"args": ["-c", "cmd --mcp -w $(pwd)"]

// Generic (specify path)
"args": ["--mcp", "-w", "/path/to/project"]
```

## Example Implementation

For reference, see the Augment Context Engine implementation:

| File | Purpose |
|------|---------|
| `.agent/tools/context/augment-context-engine.md` | Documentation |
| `configs/augment-context-engine-config.json.txt` | Config template |
| `configs/mcp-templates/augment-context-engine.json` | MCP snippets |
| `.agent/scripts/generate-opencode-agents.sh` | Agent config |
| `.agent/scripts/ai-cli-config.sh` | CLI config function |
| `setup.sh` | Setup function |

Search for `augment-context-engine` in these files to see the patterns.
