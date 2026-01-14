---
description: Peekaboo - macOS screen capture and GUI automation CLI with MCP server for AI agents
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Peekaboo - macOS Screen Capture and GUI Automation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: macOS screen capture, AI vision analysis, and complete GUI automation for AI agents
- **Platform**: macOS 15+ (Sequoia) only
- **Install CLI**: `brew install steipete/tap/peekaboo`
- **Install MCP**: `npx -y @steipete/peekaboo`
- **GitHub**: https://github.com/steipete/Peekaboo
- **Website**: https://peekaboo.boo

**Core Capabilities**:
- Pixel-accurate screen/window/menu bar captures with optional Retina 2x scaling
- Natural language agent for chained automation (see, click, type, scroll, hotkey, menu, window, app, dock, space)
- Menu and menubar discovery with structured JSON
- Multi-provider AI vision: GPT-5.1, Claude 4.x, Grok 4, Gemini 2.5, Ollama

**Requirements**: macOS Screen Recording + Accessibility permissions

**Quick Start**:

```bash
# Capture full screen at Retina scale
peekaboo image --mode screen --retina --path ~/Desktop/screen.png

# Click a button by label
peekaboo see --app Safari --json-output | jq -r '.data.snapshot_id' | read SNAPSHOT
peekaboo click --on "Reload this page" --snapshot "$SNAPSHOT"

# Natural language automation
peekaboo "Open Notes and create a TODO list with three items"
```

<!-- AI-CONTEXT-END -->

## Installation

### Homebrew (CLI + App)

```bash
brew install steipete/tap/peekaboo
```

This installs:
- `peekaboo` CLI binary
- Peekaboo.app (menu bar helper)

### MCP Server (for Claude Desktop/Cursor)

```bash
# Run directly with npx (no global install needed)
npx -y @steipete/peekaboo
```

### Verify Installation

```bash
peekaboo --version
peekaboo permissions status
```

## Permissions Setup

Peekaboo requires two macOS permissions:

### Screen Recording

Required for capturing screenshots of any application.

```bash
# Check status
peekaboo permissions status

# Grant (opens System Preferences)
peekaboo permissions grant
```

Manual: System Preferences > Privacy & Security > Screen Recording > Enable for Peekaboo

### Accessibility

Required for GUI automation (clicking, typing, menu access).

Manual: System Preferences > Privacy & Security > Accessibility > Enable for Peekaboo

## Core Commands

### Image Capture

```bash
# Full screen capture
peekaboo image --mode screen --path ~/Desktop/screen.png

# Specific window
peekaboo image --mode window --app Safari --path ~/Desktop/safari.png

# Menu bar only
peekaboo image --mode menu --path ~/Desktop/menubar.png

# Retina (2x) resolution
peekaboo image --mode screen --retina --path ~/Desktop/screen@2x.png

# With AI analysis
peekaboo image --mode screen --analyze "What applications are visible?"
```

| Option | Description |
|--------|-------------|
| `--mode screen/window/menu` | Capture target |
| `--app <name>` | Target application (for window mode) |
| `--retina` | 2x resolution output |
| `--path <file>` | Output file path |
| `--analyze <prompt>` | AI vision analysis |

### See (Capture + Annotate)

Captures UI and returns snapshot with element IDs for subsequent actions:

```bash
# Capture app UI with element annotations
peekaboo see --app Safari --json-output

# Full screen with annotations
peekaboo see --mode screen --json-output

# Returns snapshot_id for use with click/type commands
```

### Click

```bash
# Click by element ID from snapshot
peekaboo click --on @e42 --snapshot "$SNAPSHOT_ID"

# Click by label/query
peekaboo click --on "Submit" --snapshot "$SNAPSHOT_ID"

# Click by coordinates
peekaboo click --x 100 --y 200

# Click with wait
peekaboo click --on "Login" --snapshot "$SNAPSHOT_ID" --wait 2000
```

### Type

```bash
# Type text
peekaboo type --text "Hello, World!"

# Clear field first
peekaboo type --text "new value" --clear

# With delay between keystrokes
peekaboo type --text "slow typing" --delay-ms 100
```

### Press (Special Keys)

```bash
# Single key
peekaboo press Enter
peekaboo press Tab
peekaboo press Escape

# Repeat
peekaboo press Tab --repeat 3
```

### Hotkey (Modifier Combos)

```bash
# Common shortcuts
peekaboo hotkey cmd,c          # Copy
peekaboo hotkey cmd,v          # Paste
peekaboo hotkey cmd,shift,t    # Reopen tab
peekaboo hotkey cmd,alt,esc    # Force quit dialog
```

### Scroll

```bash
# Scroll by element
peekaboo scroll --on @e15 --direction down --ticks 5

# Scroll directions: up, down, left, right
peekaboo scroll --direction up --ticks 10
```

### Swipe (Gesture)

```bash
# Smooth gesture-style drag
peekaboo swipe --from 100,100 --to 100,500 --duration 500 --steps 20
```

### Drag

```bash
# Drag between elements
peekaboo drag --from @e10 --to @e20

# Drag to coordinates
peekaboo drag --from @e10 --to 500,300

# Drag to Dock/Trash
peekaboo drag --from @e10 --to Trash
```

### Move (Cursor)

```bash
# Move cursor to element
peekaboo move --to @e5

# Move to coordinates
peekaboo move --to 500,300

# Move to specific screen
peekaboo move --to 500,300 --screen-index 1
```

### Window Management

```bash
# List all windows
peekaboo window list

# Focus window
peekaboo window focus --app Safari

# Move window
peekaboo window move --app Safari --x 100 --y 100

# Resize window
peekaboo window resize --app Safari --width 1200 --height 800

# Set bounds
peekaboo window set-bounds --app Safari --x 0 --y 0 --width 1920 --height 1080
```

### App Control

```bash
# List running apps
peekaboo app list

# Launch app
peekaboo app launch Safari

# Quit app
peekaboo app quit Safari

# Relaunch app
peekaboo app relaunch Safari

# Switch to app
peekaboo app switch Safari
```

### Space (Virtual Desktops)

```bash
# List spaces
peekaboo space list

# Switch to space
peekaboo space switch 2

# Move window to space
peekaboo space move-window --app Safari --space 3
```

### Menu Interaction

```bash
# List app menus
peekaboo menu list --app Safari

# List all menu items
peekaboo menu list-all --app Safari

# Click menu item
peekaboo menu click --app Safari --menu "File" --item "New Window"

# Click extra menu items
peekaboo menu click-extra --app Safari --item "Extensions"
```

### Menubar (Status Bar)

```bash
# List menubar items
peekaboo menubar list

# Click menubar item by name
peekaboo menubar click --name "Wi-Fi"

# Click by index
peekaboo menubar click --index 3
```

### Dock

```bash
# List dock items
peekaboo dock list

# Launch from dock
peekaboo dock launch Safari

# Right-click dock item
peekaboo dock right-click Safari

# Hide/show dock
peekaboo dock hide
peekaboo dock show
```

### Dialog Handling

```bash
# List dialogs
peekaboo dialog list

# Click dialog button
peekaboo dialog click --button "OK"

# Input to dialog
peekaboo dialog input --text "filename.txt"

# File dialog
peekaboo dialog file --path ~/Documents/file.txt

# Dismiss dialog
peekaboo dialog dismiss
```

### List (Enumerate)

```bash
# List running apps
peekaboo list apps

# List windows
peekaboo list windows

# List screens
peekaboo list screens

# List menubar items
peekaboo list menubar

# Check permissions
peekaboo list permissions
```

### Agent (Natural Language)

```bash
# Natural language automation
peekaboo agent "Open Safari and navigate to github.com"

# With specific model
peekaboo agent --model gpt-5.1 "Find and click the login button"

# Dry run (show plan without executing)
peekaboo agent --dry-run "Close all Safari windows"

# Resume previous session
peekaboo agent --resume

# Limit steps
peekaboo agent --max-steps 10 "Complete the checkout process"
```

### Utility Commands

```bash
# Sleep (delay)
peekaboo sleep --duration 1000  # milliseconds

# Clean snapshots
peekaboo clean --all-snapshots
peekaboo clean --older-than 7d
peekaboo clean --snapshot "$SNAPSHOT_ID"

# View available tools
peekaboo tools --verbose --json-output

# Configuration
peekaboo config init
peekaboo config show
peekaboo config add openai
peekaboo config login anthropic
peekaboo config models
```

## MCP Server Configuration

### Claude Desktop

Add to Claude Desktop config (`Developer > Edit Config`):

```json
{
  "mcpServers": {
    "peekaboo": {
      "command": "npx",
      "args": ["-y", "@steipete/peekaboo"],
      "env": {
        "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.1,anthropic/claude-opus-4"
      }
    }
  }
}
```

### OpenCode

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "peekaboo": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@steipete/peekaboo"],
      "env": {
        "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.1"
      }
    }
  }
}
```

### Cursor

Add to Cursor MCP settings:

```json
{
  "mcpServers": {
    "peekaboo": {
      "command": "npx",
      "args": ["-y", "@steipete/peekaboo"]
    }
  }
}
```

## AI Providers

Peekaboo supports multiple AI providers for vision analysis:

| Provider | Models | Environment Variable |
|----------|--------|---------------------|
| OpenAI | GPT-5.1, GPT-4.1, GPT-4o | `OPENAI_API_KEY` |
| Anthropic | Claude 4.x | `ANTHROPIC_API_KEY` |
| xAI | Grok 4-fast | `XAI_API_KEY` |
| Google | Gemini 2.5 (pro/flash) | `GOOGLE_API_KEY` |
| Ollama | llama3.3, llava, etc. | Local (no key needed) |

### Configure Providers

```bash
# Add provider via CLI
peekaboo config add openai
peekaboo config add anthropic

# Or set environment variable
export PEEKABOO_AI_PROVIDERS="openai/gpt-5.1,anthropic/claude-opus-4"
```

### Using Ollama (Local)

```bash
# Install Ollama
brew install ollama

# Pull a vision model
ollama pull llava

# Use with Peekaboo
peekaboo image --mode screen --analyze "What's on screen?" --model ollama/llava
```

## Workflow Patterns

### Screenshot + AI Analysis

```bash
# Capture and analyze in one command
peekaboo image --mode screen --analyze "List all visible applications and their states"

# Or two-step for more control
peekaboo image --mode screen --path /tmp/screen.png
# Then use with external AI
```

### Automated Form Filling

```bash
# 1. Capture UI with element IDs
SNAPSHOT=$(peekaboo see --app Safari --json-output | jq -r '.data.snapshot_id')

# 2. Fill form fields
peekaboo click --on "Email" --snapshot "$SNAPSHOT"
peekaboo type --text "user@example.com"

peekaboo click --on "Password" --snapshot "$SNAPSHOT"
peekaboo type --text "secure-password"

peekaboo click --on "Submit" --snapshot "$SNAPSHOT"
```

### Menu Navigation

```bash
# Open specific menu item
peekaboo menu click --app "Visual Studio Code" --menu "File" --item "New File"

# Or use hotkey
peekaboo hotkey cmd,n
```

### Multi-Window Workflow

```bash
# List windows to find targets
peekaboo window list --json-output

# Focus specific window
peekaboo window focus --app Safari --title "GitHub"

# Arrange windows
peekaboo window set-bounds --app Safari --x 0 --y 0 --width 960 --height 1080
peekaboo window set-bounds --app "VS Code" --x 960 --y 0 --width 960 --height 1080
```

### Natural Language Automation

```bash
# Complex multi-step task
peekaboo agent "Open Safari, go to github.com, search for 'peekaboo', and star the first repository"

# With step limit for safety
peekaboo agent --max-steps 5 "Close all notification windows"
```

## Comparison with Other Tools

| Feature | Peekaboo | agent-browser | Stagehand | Playwright |
|---------|----------|---------------|-----------|------------|
| Platform | macOS only | Cross-platform | Cross-platform | Cross-platform |
| Target | Native apps + web | Web browsers | Web browsers | Web browsers |
| Interface | CLI + MCP | CLI | SDK | SDK |
| AI Vision | Built-in | - | Natural language | - |
| Menu Access | Native macOS | - | - | - |
| Dock/Spaces | Yes | - | - | - |
| Screen Capture | Native | Screenshot | Screenshot | Screenshot |

### When to Use Peekaboo

- **macOS native app automation** - Finder, System Preferences, native apps
- **Screen capture with AI analysis** - Vision-based understanding
- **Menu bar and dock interaction** - Status items, dock apps
- **Multi-space workflows** - Virtual desktop management
- **Natural language automation** - Agent-based task execution

### When to Use Other Tools

- **Cross-platform web automation** - Use agent-browser, Playwright, or Stagehand
- **Linux/Windows** - Peekaboo is macOS-only
- **Browser-specific features** - Use browser-focused tools

## Troubleshooting

### Permission Issues

```bash
# Check permission status
peekaboo permissions status

# If denied, reset and re-grant
tccutil reset ScreenCapture com.steipete.Peekaboo
tccutil reset Accessibility com.steipete.Peekaboo
peekaboo permissions grant
```

### MCP Connection Issues

```bash
# Test MCP server directly
npx -y @steipete/peekaboo --help

# Check for port conflicts
lsof -i :3000

# Verify Node.js version (requires 22+)
node --version
```

### Snapshot Issues

```bash
# Clean old snapshots
peekaboo clean --all-snapshots

# Check snapshot directory
ls -la ~/.peekaboo/snapshots/
```

## Resources

- **GitHub**: https://github.com/steipete/Peekaboo
- **Website**: https://peekaboo.boo
- **npm Package**: https://www.npmjs.com/package/@steipete/peekaboo
- **Homebrew Tap**: https://github.com/steipete/homebrew-tap
- **Documentation**: https://github.com/steipete/Peekaboo/tree/main/docs
- **License**: MIT
