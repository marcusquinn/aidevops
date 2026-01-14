---
description: macOS Automator MCP for AppleScript and JXA automation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  macos-automator_*: true
---

# macOS Automator MCP Setup

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Execute AppleScript and JXA (JavaScript for Automation) on macOS
- **Install**: `npm install -g @steipete/macos-automator-mcp@0.2.0`
- **Auth**: None required (uses macOS permissions)
- **MCP Tools**: `execute_script`, `get_scripting_tips`, `accessibility_query`
- **Docs**: <https://github.com/steipete/macos-automator-mcp>

**OpenCode Config**:

```json
"macos-automator": {
  "type": "local",
  "command": ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"],
  "enabled": true
}
```

**Verification Prompt**:

```text
Use the macos-automator MCP to get the current Safari URL.
```

**Supported AI Tools**: OpenCode, Claude Code, Cursor, Windsurf, Zed, GitHub Copilot,
Kilo Code, Kiro, AntiGravity, Gemini CLI, Droid (Factory.AI)

**Enabled for Agents**: None by default. Enable via `@mac` subagent.

**macOS Permissions Required**:
- System Settings > Privacy & Security > Automation
- System Settings > Privacy & Security > Accessibility

<!-- AI-CONTEXT-END -->

## What It Does

The macOS Automator MCP provides **full macOS automation** via AppleScript and JXA:

| Feature | Description |
|---------|-------------|
| AppleScript execution | Run any AppleScript code |
| JXA execution | Run JavaScript for Automation |
| Knowledge base | 200+ pre-built automation scripts |
| Accessibility queries | Inspect and interact with UI elements |
| App control | Control any macOS application |

Use it to:

- Control Safari, Finder, Mail, Calendar, and other apps
- Automate file system operations
- Send notifications and control system settings
- Interact with UI elements via accessibility API
- Execute complex multi-step automations

## Prerequisites

- **macOS** (required - AppleScript is macOS-only)
- **Node.js 18+** required
- **macOS Permissions** (see below)

### Required Permissions

The application running the MCP server needs explicit permissions:

1. **Automation Permissions**:
   - Go to: System Settings > Privacy & Security > Automation
   - Find Terminal (or your AI tool) in the list
   - Enable checkboxes for apps you want to control

2. **Accessibility Permissions** (for UI scripting):
   - Go to: System Settings > Privacy & Security > Accessibility
   - Add Terminal (or your AI tool) to the list
   - Ensure checkbox is enabled

## Installation

### 1. Install via npx (Recommended)

No installation needed - runs directly via npx:

```bash
npx -y @steipete/macos-automator-mcp@0.2.0
```

### 2. Or Install Globally

```bash
npm install -g @steipete/macos-automator-mcp@0.2.0
```

### 3. Verify Installation

```bash
# Test that it runs
npx -y @steipete/macos-automator-mcp@0.2.0 --help
```

## AI Tool Configurations

### OpenCode

Edit `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "macos-automator": {
      "type": "local",
      "command": ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"],
      "enabled": true
    }
  },
  "tools": {
    "macos-automator_*": false
  }
}
```

Then enable via `@mac` subagent or per-agent in the `agent` section:

```json
"agent": {
  "Build+": {
    "tools": {
      "macos-automator_*": true
    }
  }
}
```

### Claude Code

Add via CLI command:

```bash
# User scope (all projects)
claude mcp add-json macos-automator --scope user '{"type":"stdio","command":"npx","args":["-y","@steipete/macos-automator-mcp@0.2.0"]}'

# Project scope (current project only)
claude mcp add-json macos-automator --scope project '{"type":"stdio","command":"npx","args":["-y","@steipete/macos-automator-mcp@0.2.0"]}'
```

### Cursor

Go to Settings > Tools & MCP > New MCP Server:

```json
{
  "mcpServers": {
    "macos-automator": {
      "command": "npx",
      "args": ["-y", "@steipete/macos-automator-mcp@0.2.0"]
    }
  }
}
```

### Windsurf

Edit `~/.codeium/windsurf/mcp.json`:

```json
{
  "mcpServers": {
    "macos-automator": {
      "command": "npx",
      "args": ["-y", "@steipete/macos-automator-mcp@0.2.0"]
    }
  }
}
```

### Zed

Click ... > Add Custom Server:

```json
{
  "macos-automator": {
    "command": "npx",
    "args": ["-y", "@steipete/macos-automator-mcp@0.2.0"],
    "env": {}
  }
}
```

### GitHub Copilot

Create `.vscode/mcp.json` in your project root:

```json
{
  "servers": {
    "macos-automator": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@steipete/macos-automator-mcp@0.2.0"]
    }
  },
  "inputs": []
}
```

### Gemini CLI

Edit `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "macos-automator": {
      "command": "npx",
      "args": ["-y", "@steipete/macos-automator-mcp@0.2.0"]
    }
  }
}
```

### Droid (Factory.AI)

Add via CLI:

```bash
droid mcp add macos-automator "npx" -y @steipete/macos-automator-mcp@0.2.0
```

## MCP Tools

### execute_script

Execute AppleScript or JXA code.

**Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `script_content` | string | Raw script code (mutually exclusive with script_path, kb_script_id) |
| `script_path` | string | Absolute path to script file |
| `kb_script_id` | string | ID of pre-defined script from knowledge base |
| `language` | enum | 'applescript' or 'javascript' (default: applescript) |
| `arguments` | array | Arguments to pass to script |
| `input_data` | object | Named inputs for knowledge base scripts |
| `timeout_seconds` | integer | Max execution time (default: 60) |

**Examples**:

Get Safari URL:

```json
{
  "script_content": "tell application \"Safari\" to get URL of front document",
  "language": "applescript"
}
```

Use knowledge base script:

```json
{
  "kb_script_id": "safari_get_active_tab_url"
}
```

Toggle dark mode:

```json
{
  "kb_script_id": "systemsettings_toggle_dark_mode_ui"
}
```

### get_scripting_tips

Search the knowledge base of 200+ pre-built scripts.

**Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `list_categories` | boolean | List available categories |
| `category` | string | Filter by category (e.g., "finder", "safari") |
| `search_term` | string | Search in titles, descriptions, content |
| `limit` | integer | Max results (default: 10) |

**Examples**:

List all categories:

```json
{ "list_categories": true }
```

Search for clipboard scripts:

```json
{ "search_term": "clipboard" }
```

Get Safari automation tips:

```json
{ "category": "safari" }
```

### accessibility_query

Query and interact with UI elements via accessibility API.

**Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `command` | enum | 'query' or 'perform' |
| `locator.app` | string | Target application (name or bundle ID) |
| `locator.role` | string | Accessibility role (e.g., "AXButton") |
| `locator.match` | object | Attributes to match |
| `action_to_perform` | string | Action for 'perform' command (e.g., "AXPress") |

**Examples**:

```json
// Find all buttons in System Settings
{
  "command": "query",
  "return_all_matches": true,
  "locator": {
    "app": "System Settings",
    "role": "AXButton",
    "match": {}
  }
}

// Click a specific button
{
  "command": "perform",
  "locator": {
    "app": "System Settings",
    "role": "AXButton",
    "match": {"AXTitle": "General"}
  },
  "action_to_perform": "AXPress"
}
```

## Common Use Cases

### Application Control

```applescript
-- Get Safari URL
tell application "Safari" to get URL of front document

-- Get unread email subjects
tell application "Mail" to get subject of messages of inbox whose read status is false

-- Play/pause Music
tell application "Music" to playpause
```

### File System Operations

```applescript
-- List desktop files
tell application "Finder" to get name of every item of desktop

-- Create new folder
tell application "Finder" to make new folder at desktop with properties {name:"New Folder"}
```

### System Control

```applescript
-- Display notification
display notification "Task complete!" with title "Automation"

-- Set volume
set volume output volume 50

-- Get clipboard
the clipboard
```

## Verification

After configuring, test with this prompt:

```text
Use the macos-automator MCP to get the current Safari URL.
```

The AI should:

1. Confirm access to `execute_script` tool
2. Execute AppleScript to get Safari URL
3. Return the URL of the front Safari tab

## Troubleshooting

### "Permission denied" errors

1. Open System Settings > Privacy & Security > Automation
2. Find your terminal/AI tool
3. Enable permissions for the apps you want to control

### "Accessibility access required"

1. Open System Settings > Privacy & Security > Accessibility
2. Add your terminal/AI tool to the list
3. Ensure checkbox is enabled

### Script timeout

Increase `timeout_seconds` parameter (default is 60):

```json
{
  "script_content": "...",
  "timeout_seconds": 120
}
```

### "Application not found"

Use exact application name or bundle ID:

```applescript
-- By name
tell application "Safari" to ...

-- By bundle ID
tell application id "com.apple.Safari" to ...
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `LOG_LEVEL` | Logging verbosity: DEBUG, INFO, WARN, ERROR |
| `KB_PARSING` | Knowledge base loading: lazy (default) or eager |
| `LOCAL_KB_PATH` | Custom knowledge base path (default: ~/.macos-automator/knowledge_base) |

## Custom Knowledge Base

Create custom automation scripts at `~/.macos-automator/knowledge_base/`:

```text
~/.macos-automator/knowledge_base/
  01_applescript_core/
    my_custom_script.md
  05_web_browsers/
    safari/
      my_safari_script.md
```

Scripts with matching IDs override the built-in knowledge base.

## Updates

Check for updates at:
<https://github.com/steipete/macos-automator-mcp>

## Related Documentation

- [Stagehand](../browser/stagehand.md) - Browser automation
- [Playwright](../browser/playwright.md) - Cross-browser testing
