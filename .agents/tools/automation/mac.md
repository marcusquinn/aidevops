---
description: macOS automation via AppleScript and JXA
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

# @mac - macOS Automation Subagent

Invoke with `@mac` to enable the macos-automator MCP tools for AppleScript and JXA automation.

## Tools

| Tool | Purpose |
|------|---------|
| `execute_script` | Run AppleScript or JXA code |
| `get_scripting_tips` | Search 200+ pre-built automation scripts |
| `accessibility_query` | Query and interact with UI elements |

## Examples

```text
@mac Get the current Safari URL
@mac What apps are currently running?
@mac Toggle dark mode
@mac Set volume to 50%
@mac Open Safari and navigate to github.com
@mac Click the "General" button in System Settings
@mac Find all text fields in the current app
@mac Send a notification saying "Task complete"
@mac Search for clipboard scripts
```

The MCP includes 200+ pre-built scripts searchable via `get_scripting_tips` (categories, search terms, or browse all).

## Requirements

- **macOS only** — AppleScript is macOS-specific
- **Permissions**: System Settings > Privacy & Security > Automation + Accessibility

## Full Documentation

See `tools/automation/macos-automator.md` for setup, configuration, and tool parameter reference.
