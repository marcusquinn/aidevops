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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# @mac - macOS Automation

Use `@mac` for local macOS automation via AppleScript, JXA, and Accessibility APIs.

## Quick Reference

- **Scope**: macOS-only app, UI, and system automation
- **Tools**: `execute_script`, `get_scripting_tips`, `accessibility_query`
- **Permissions**: System Settings > Privacy & Security > Automation and Accessibility
- **Details**: `tools/automation/macos-automator.md`

## Tool Use

| Tool | Purpose |
|------|---------|
| `execute_script` | Run AppleScript or JXA code directly |
| `get_scripting_tips` | Search 200+ built-in scripts before writing custom automation |
| `accessibility_query` | Inspect or click UI elements when an app lacks a scripting API |

## Example Prompts

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

## Related

- `tools/automation/macos-automator.md` — Installation and parameter details

