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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# macOS Automator MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Execute AppleScript and JXA (JavaScript for Automation) on macOS
- **Install**: `npm install -g @steipete/macos-automator-mcp@0.2.0`
- **Auth**: None (uses macOS permissions)
- **MCP Tools**: `execute_script`, `get_scripting_tips`, `accessibility_query`
- **Docs**: <https://github.com/steipete/macos-automator-mcp>
- **Enabled for Agents**: None by default — enable via `@mac` subagent
- **Supported**: OpenCode, Claude Code, Cursor, Windsurf, Zed, GitHub Copilot, Kilo Code, Kiro, Gemini CLI, Droid (Factory.AI)

**Verification**: `Use the macos-automator MCP to get the current Safari URL.`

<!-- AI-CONTEXT-END -->

## Prerequisites

Node.js 18+. Grant Automation and Accessibility permissions to your terminal/AI tool via System Settings > Privacy & Security.

## Installation

```bash
npx -y @steipete/macos-automator-mcp@0.2.0        # run directly
npm install -g @steipete/macos-automator-mcp@0.2.0  # or install globally
```

## AI Tool Configurations

Most tools use the same `mcpServers` JSON shape:

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

Config locations: **Cursor** → Settings > Tools & MCP | **Windsurf** → `~/.codeium/windsurf/mcp.json` | **Zed** → Add Custom Server (add `"env": {}`) | **Gemini CLI** → `~/.gemini/settings.json`

**GitHub Copilot** uses `"servers"` key in `.vscode/mcp.json` with `"type": "stdio"` added.

**Claude Code**:
```bash
claude mcp add-json macos-automator --scope user \
  '{"type":"stdio","command":"npx","args":["-y","@steipete/macos-automator-mcp@0.2.0"]}'
```

**OpenCode** (`~/.config/opencode/opencode.json`) — uses `"type": "local"` and supports per-agent tool gating:
```json
{
  "mcp": { "macos-automator": { "type": "local", "command": ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"], "enabled": true } },
  "tools": { "macos-automator_*": false },
  "agent": { "Build+": { "tools": { "macos-automator_*": true } } }
}
```

**Droid**: `droid mcp add macos-automator "npx" -y @steipete/macos-automator-mcp@0.2.0`

## MCP Tools

### execute_script

Parameters: `script_content` (string, raw code) | `script_path` (string, absolute path) | `kb_script_id` (string, knowledge base ID) — mutually exclusive. Also: `language` (`applescript`/`javascript`, default applescript), `arguments` (array), `input_data` (object), `timeout_seconds` (integer, default 60).

```json
{ "script_content": "tell application \"Safari\" to get URL of front document", "language": "applescript" }
{ "kb_script_id": "safari_get_active_tab_url" }
```

### get_scripting_tips

Parameters: `list_categories` (boolean), `category` (string), `search_term` (string), `limit` (integer, default 10).

```json
{ "list_categories": true }
{ "search_term": "clipboard" }
{ "category": "safari" }
```

### accessibility_query

Parameters: `command` (`query`/`perform`), `locator.app`, `locator.role`, `locator.match`, `action_to_perform`.

```json
{ "command": "query", "return_all_matches": true, "locator": { "app": "System Settings", "role": "AXButton", "match": {} } }
{ "command": "perform", "locator": { "app": "System Settings", "role": "AXButton", "match": { "AXTitle": "General" } }, "action_to_perform": "AXPress" }
```

## Common Scripts

```applescript
tell application "Safari" to get URL of front document
tell application "Mail" to get subject of messages of inbox whose read status is false
tell application "Music" to playpause
tell application "Finder" to get name of every item of desktop
tell application "Finder" to make new folder at desktop with properties {name:"New Folder"}
display notification "Task complete!" with title "Automation"
set volume output volume 50
the clipboard
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `LOG_LEVEL` | `DEBUG`, `INFO`, `WARN`, `ERROR` |
| `KB_PARSING` | `lazy` (default) or `eager` |
| `LOCAL_KB_PATH` | Custom KB path (default: `~/.macos-automator/knowledge_base`) |

Custom scripts at `~/.macos-automator/knowledge_base/` override built-ins by matching ID.

## Troubleshooting

| Error | Fix |
|-------|-----|
| `Permission denied` | System Settings > Privacy & Security > Automation — enable your terminal/tool |
| `Accessibility access required` | System Settings > Privacy & Security > Accessibility — add your terminal/tool |
| Script timeout | Add `"timeout_seconds": 120` |
| `Application not found` | Use bundle ID: `tell application id "com.apple.Safari"` |

## Related

- [Stagehand](../browser/stagehand.md) — Browser automation
- [Playwright](../browser/playwright.md) — Cross-browser testing
