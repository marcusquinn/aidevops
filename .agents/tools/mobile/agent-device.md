---
description: Agent Device - token-efficient iOS and Android device automation CLI for AI agents
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

# Agent Device - Mobile Automation for AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: CLI to control iOS and Android devices for AI agents (mobile counterpart to agent-browser)
- **Install**: `npm install -g agent-device` or `npx agent-device`
- **Requirements**: Node 22+, Xcode (iOS simulators), Android SDK (Android emulators/devices)
- **GitHub**: https://github.com/callstackincubator/agent-device (489 stars, MIT)
- **Author**: Michal Pierzchala (@thymikee), Callstack
- **Docs**: https://incubator.callstack.com/agent-device

**Core Workflow** (optimal for AI):

```bash
agent-device open Contacts --platform ios   # Start session on iOS Simulator
agent-device snapshot                        # Get accessibility tree with refs
agent-device click @e5                       # Click by ref from snapshot
agent-device fill @e6 "John"                 # Fill by ref
agent-device screenshot contact.png          # Capture screen
agent-device close                           # End session
```

**Key Advantages**:

- **Ref-based selection**: Deterministic element targeting from accessibility snapshots
- **Token-efficient**: Designed for AI agents — minimal output, structured data
- **Cross-platform**: iOS simulators + Android emulators/devices in one CLI
- **Minimal dependencies**: Single npm dependency (`@clack/prompts`)
- **No MCP required**: Pure CLI — works with any AI agent via Bash

**When to use agent-device vs other mobile tools**:

| Tool | Best For |
|------|----------|
| **agent-device** | AI-driven mobile app interaction and testing (CLI, both platforms) |
| `xcodebuild-mcp` | Building, testing, deploying iOS/macOS apps (MCP, Xcode-focused) |
| `ios-simulator-mcp` | iOS simulator interaction via MCP protocol (MCP, iOS only) |
| `maestro` | Human-authored YAML E2E test flows (declarative, both platforms) |
| `minisim` | Quick simulator/emulator launching from menu bar (GUI) |

<!-- AI-CONTEXT-END -->

## Command Index

### Session Management

| Command | Description |
|---------|-------------|
| `open <app>` | Start session, launch app (by name or bundle ID) |
| `open <app> --platform ios\|android` | Specify platform |
| `open <app> --device <name>` | Target specific device |
| `open <app> --session <name>` | Named session for multi-device |
| `close` | End session, release device resources |
| `session list` | List active sessions |

### Inspection

| Command | Description |
|---------|-------------|
| `snapshot` | Get accessibility tree with element refs (@e1, @e2...) |
| `snapshot -s "<label>"` | Scoped snapshot (subtree only) |
| `snapshot -s @e5` | Scoped snapshot by ref |
| `snapshot --raw` | Unaltered accessibility output (debugging) |
| `find <text> <action>` | Semantic find by any text (label/value/identifier) |
| `find label\|value\|role\|id <value> <action>` | Find by specific locator |
| `get text @e5` | Get text content of element |
| `appstate` | Show foreground app/activity |
| `apps --metadata` | List installed apps |
| `devices` | List available devices |

### Interaction

| Command | Description |
|---------|-------------|
| `click @e5` | Click element by ref |
| `focus @e5` | Focus element |
| `fill @e5 "text"` | Clear and type text into element |
| `type "text"` | Type into focused field (no clear) |
| `press <x> <y>` | Tap at coordinates |
| `long-press <x> <y>` | Long press at coordinates |
| `scroll up\|down\|left\|right` | Scroll in direction |
| `scrollintoview @e5` | Scroll until element visible |
| `back` | Navigate back |
| `home` | Go to home screen |
| `app-switcher` | Open app switcher |
| `alert accept\|dismiss` | Handle system alerts |
| `wait <ms>` | Wait for duration |

### Settings (Simulators)

| Command | Description |
|---------|-------------|
| `settings wifi on\|off` | Toggle WiFi |
| `settings airplane on\|off` | Toggle airplane mode |
| `settings location on\|off` | Toggle location services |

### Debug

| Command | Description |
|---------|-------------|
| `trace start` | Start recording trace log |
| `trace stop ./trace.log` | Stop and save trace |
| `screenshot <file>` | Save screenshot to file |

## AI Agent Workflow

Typical AI agent loop for mobile testing:

```bash
# 1. Open app
agent-device open "My App" --platform ios --json

# 2. Observe state
agent-device snapshot --json

# 3. Interact based on snapshot refs
agent-device click @e3
agent-device fill @e7 "test@example.com"

# 4. Verify result
agent-device snapshot --json

# 5. Screenshot for evidence
agent-device screenshot ./evidence.png

# 6. Clean up
agent-device close
```

Use `--json` flag for structured output suitable for machine parsing.

## iOS Backends

| Backend | Speed | Accuracy | Requirements |
|---------|-------|----------|--------------|
| `xctest` (default) | Fast | High | No Accessibility permission needed |
| `ax` | Fast | Medium | Accessibility permission for terminal app |

Select with `--backend ax|xctest` on snapshot commands.

## Platform Notes

- **iOS**: Input commands (`press`, `type`, `scroll`) are simulator-only in v1 (uses XCTest runner)
- **Android**: `fill` verifies entered value and retries with slower typing if IME causes character swaps
- **App resolution**: Accepts bundle IDs (`com.apple.Preferences`) or human names (`Settings`)
- **Session logs**: Written to `~/.agent-device/sessions/`

## Skills Integration

agent-device ships with a SKILL.md for Claude Code / agent-skills compatible tools:

```bash
npx skills add https://github.com/callstackincubator/agent-device --skill agent-device
```

Or for aidevops:

```bash
aidevops skill add https://github.com/callstackincubator/agent-device
```
