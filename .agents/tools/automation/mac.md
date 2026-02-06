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

Use this subagent to enable macOS automation capabilities via AppleScript and JXA.

## Quick Start

Invoke with `@mac` to enable the macos-automator MCP tools:

```text
@mac Get the current Safari URL
@mac Toggle dark mode
@mac List files on the desktop
@mac Send a notification saying "Task complete"
```

## Available Tools

When `@mac` is invoked, you gain access to:

| Tool | Purpose |
|------|---------|
| `execute_script` | Run AppleScript or JXA code |
| `get_scripting_tips` | Search 200+ pre-built automation scripts |
| `accessibility_query` | Query and interact with UI elements |

## Common Tasks

### Get Information

```text
@mac What's the current Safari URL?
@mac What apps are currently running?
@mac What's on my clipboard?
```

### Control Applications

```text
@mac Open Safari and navigate to github.com
@mac Play the next track in Music
@mac Create a new folder called "Projects" on my desktop
```

### System Control

```text
@mac Toggle dark mode
@mac Set volume to 50%
@mac Show a notification with title "Done" and message "Task complete"
```

### UI Automation

```text
@mac Click the "General" button in System Settings
@mac Find all text fields in the current app
@mac What buttons are visible in Finder?
```

## Knowledge Base

The MCP includes 200+ pre-built scripts. Search them:

```text
@mac Search for clipboard scripts
@mac List all Safari automation tips
@mac Show me file system automation options
```

## Requirements

- **macOS only** - AppleScript is macOS-specific
- **Permissions required**:
  - System Settings > Privacy & Security > Automation
  - System Settings > Privacy & Security > Accessibility

## Full Documentation

See `tools/automation/macos-automator.md` for complete setup and configuration.
