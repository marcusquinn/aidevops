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

# macOS Automator MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Execute AppleScript and JXA (JavaScript for Automation) on macOS
- **Install**: `npm install -g @steipete/macos-automator-mcp@0.2.0`
- **Auth**: None (uses macOS permissions)
- **MCP Tools**: `execute_script`, `get_scripting_tips`, `accessibility_query`
- **Docs**: <https://github.com/steipete/macos-automator-mcp>
- **Enabled for Agents**: None by default — enable via `@mac` subagent

**Supported AI Tools**: OpenCode, Claude Code, Cursor, Windsurf, Zed, GitHub Copilot, Kilo Code, Kiro, Gemini CLI, Droid (Factory.AI)

**Verification prompt**: `Use the macos-automator MCP to get the current Safari URL.`

<!-- AI-CONTEXT-END -->

## Prerequisites

- macOS (required — AppleScript is macOS-only), Node.js 18+

**Required permissions** (grant to Terminal or your AI tool):

| Permission | Path |
|------------|------|
| Automation | System Settings > Privacy & Security > Automation |
| Accessibility (UI scripting) | System Settings > Privacy & Security > Accessibility |

## Installation

```bash
# Run directly (no install needed)
npx -y @steipete/macos-automator-mcp@0.2.0

# Or install globally
npm install -g @steipete/macos-automator-mcp@0.2.0
```

## AI Tool Configurations

### OpenCode

`~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "macos-automator": {
      "type": "local",
      "command": ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"],
      "enabled": true
    }
  },
  "tools": { "macos-automator_*": false },
  "agent": {
    "Build+": { "tools": { "macos-automator_*": true } }
  }
}
```

### Claude Code

```bash
# User scope (all projects)
claude mcp add-json macos-automator --scope user '{"type":"stdio","command":"npx","args":["-y","@steipete/macos-automator-mcp@0.2.0"]}'

# Project scope
claude mcp add-json macos-automator --scope project '{"type":"stdio","command":"npx","args":["-y","@steipete/macos-automator-mcp@0.2.0"]}'
```

### Cursor / Windsurf / Zed / Gemini CLI

All use the same JSON shape:

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

Config file locations:
- **Cursor**: Settings > Tools & MCP > New MCP Server
- **Windsurf**: `~/.codeium/windsurf/mcp.json`
- **Zed**: ... > Add Custom Server (add `"env": {}` field)
- **Gemini CLI**: `~/.gemini/settings.json`

### GitHub Copilot

`.vscode/mcp.json` in project root:

```json
{
  "servers": {
    "macos-automator": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@steipete/macos-automator-mcp@0.2.0"]
    }
  }
}
```

### Droid (Factory.AI)

```bash
droid mcp add macos-automator "npx" -y @steipete/macos-automator-mcp@0.2.0
```

## MCP Tools

### execute_script

| Parameter | Type | Description |
|-----------|------|-------------|
| `script_content` | string | Raw script code (mutually exclusive with `script_path`, `kb_script_id`) |
| `script_path` | string | Absolute path to script file |
| `kb_script_id` | string | Pre-defined script ID from knowledge base |
| `language` | enum | `applescript` (default) or `javascript` |
| `arguments` | array | Arguments to pass to script |
| `input_data` | object | Named inputs for knowledge base scripts |
| `timeout_seconds` | integer | Max execution time (default: 60) |

```json
{ "script_content": "tell application \"Safari\" to get URL of front document", "language": "applescript" }
{ "kb_script_id": "safari_get_active_tab_url" }
{ "kb_script_id": "systemsettings_toggle_dark_mode_ui" }
```

### get_scripting_tips

| Parameter | Type | Description |
|-----------|------|-------------|
| `list_categories` | boolean | List available categories |
| `category` | string | Filter by category (e.g., `finder`, `safari`) |
| `search_term` | string | Search titles, descriptions, content |
| `limit` | integer | Max results (default: 10) |

```json
{ "list_categories": true }
{ "search_term": "clipboard" }
{ "category": "safari" }
```

### accessibility_query

| Parameter | Type | Description |
|-----------|------|-------------|
| `command` | enum | `query` or `perform` |
| `locator.app` | string | App name or bundle ID |
| `locator.role` | string | Accessibility role (e.g., `AXButton`) |
| `locator.match` | object | Attributes to match |
| `action_to_perform` | string | Action for `perform` (e.g., `AXPress`) |

```json
{ "command": "query", "return_all_matches": true, "locator": { "app": "System Settings", "role": "AXButton", "match": {} } }
{ "command": "perform", "locator": { "app": "System Settings", "role": "AXButton", "match": { "AXTitle": "General" } }, "action_to_perform": "AXPress" }
```

## Common Scripts

```applescript
-- Safari: get URL
tell application "Safari" to get URL of front document

-- Mail: unread subjects
tell application "Mail" to get subject of messages of inbox whose read status is false

-- Music: play/pause
tell application "Music" to playpause

-- Finder: list desktop / create folder
tell application "Finder" to get name of every item of desktop
tell application "Finder" to make new folder at desktop with properties {name:"New Folder"}

-- Notification / volume / clipboard
display notification "Task complete!" with title "Automation"
set volume output volume 50
the clipboard
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `LOG_LEVEL` | Verbosity: `DEBUG`, `INFO`, `WARN`, `ERROR` |
| `KB_PARSING` | Knowledge base loading: `lazy` (default) or `eager` |
| `LOCAL_KB_PATH` | Custom KB path (default: `~/.macos-automator/knowledge_base`) |

## Custom Knowledge Base

Place scripts at `~/.macos-automator/knowledge_base/` — matching IDs override built-ins:

```text
~/.macos-automator/knowledge_base/
  01_applescript_core/my_custom_script.md
  05_web_browsers/safari/my_safari_script.md
```

## Troubleshooting

| Error | Fix |
|-------|-----|
| `Permission denied` | System Settings > Privacy & Security > Automation — enable your terminal/tool |
| `Accessibility access required` | System Settings > Privacy & Security > Accessibility — add your terminal/tool |
| Script timeout | Add `"timeout_seconds": 120` to the call |
| `Application not found` | Use exact name or bundle ID: `tell application id "com.apple.Safari"` |

## Related

- [Stagehand](../browser/stagehand.md) — Browser automation
- [Playwright](../browser/playwright.md) — Cross-browser testing
