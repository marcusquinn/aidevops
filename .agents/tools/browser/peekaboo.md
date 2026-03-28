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
- **Platform**: macOS 15+ (Sequoia) only — requires Screen Recording + Accessibility permissions
- **Install CLI**: `brew install steipete/tap/peekaboo` | **MCP**: `npx -y @steipete/peekaboo`
- **GitHub**: https://github.com/steipete/Peekaboo | **Docs**: https://github.com/steipete/Peekaboo/tree/main/docs | **Website**: https://peekaboo.boo | **npm**: https://www.npmjs.com/package/@steipete/peekaboo

**Core Capabilities**: Pixel-accurate screen/window/menu bar captures (optional Retina 2x), natural language agent for chained automation (see, click, type, scroll, hotkey, menu, window, app, dock, space), menu/menubar discovery with structured JSON, multi-provider AI vision (GPT-5.1, Claude 4.x, Grok 4, Gemini 2.5, Ollama).

```bash
peekaboo image --mode screen --retina --path ~/Desktop/screen.png       # Retina capture
SNAPSHOT=$(peekaboo see --app Safari --json-output | jq -r '.data.snapshot_id')
peekaboo click --on "Reload this page" --snapshot "$SNAPSHOT"           # Click by label
peekaboo agent "Open Notes and create a TODO list with three items"     # Natural language
```

<!-- AI-CONTEXT-END -->

## Setup

```bash
brew install steipete/tap/peekaboo && peekaboo --version
peekaboo permissions status       # Check permissions
peekaboo permissions grant        # Opens System Preferences if needed
```

Grant **Screen Recording** and **Accessibility** in System Preferences > Privacy & Security.

## Image Capture

```bash
peekaboo image --mode screen --path ~/Desktop/screen.png          # Full screen
peekaboo image --mode window --app Safari --path ~/Desktop/s.png  # Specific window
peekaboo image --mode menu --path ~/Desktop/menubar.png           # Menu bar only
peekaboo image --mode screen --retina --path ~/Desktop/s@2x.png   # Retina (2x)
peekaboo image --mode screen --analyze "What applications are visible?"  # With AI
```

| Option | Description |
|--------|-------------|
| `--mode screen/window/menu` | Capture target |
| `--app <name>` | Target application (window mode) |
| `--retina` | 2x resolution output |
| `--path <file>` | Output file path |
| `--analyze <prompt>` | AI vision analysis |

## See, Click, Type

**See** captures UI and returns a snapshot with element IDs for subsequent actions:

```bash
peekaboo see --app Safari --json-output                             # App UI with annotations
peekaboo see --mode screen --json-output                            # Full screen annotations
```

**Click** by element ID, label, or coordinates:

```bash
peekaboo click --on @e42 --snapshot "$SNAPSHOT_ID"                  # By element ID
peekaboo click --on "Submit" --snapshot "$SNAPSHOT_ID"              # By label
peekaboo click --x 100 --y 200                                      # By coordinates
peekaboo click --on "Login" --snapshot "$SNAPSHOT_ID" --wait 2000   # With wait
```

**Type** text into focused fields:

```bash
peekaboo type --text "Hello, World!"
peekaboo type --text "new value" --clear                            # Clear field first
peekaboo type --text "slow typing" --delay-ms 100
```

## Input: Press, Hotkey, Scroll, Swipe, Drag, Move

```bash
peekaboo press Enter                              # Single key
peekaboo press Tab --repeat 3                     # Repeat
peekaboo hotkey cmd,c                             # Copy
peekaboo hotkey cmd,shift,t                       # Reopen tab
peekaboo scroll --on @e15 --direction down --ticks 5
peekaboo swipe --from 100,100 --to 100,500 --duration 500 --steps 20
peekaboo drag --from @e10 --to @e20               # Between elements
peekaboo drag --from @e10 --to Trash              # To Dock/Trash
peekaboo move --to @e5                            # Move cursor to element
peekaboo move --to 500,300 --screen-index 1       # Specific screen
```

## Window, App, Space Management

```bash
# Windows
peekaboo window list | focus --app Safari | move --app Safari --x 100 --y 100
peekaboo window resize --app Safari --width 1200 --height 800
peekaboo window set-bounds --app Safari --x 0 --y 0 --width 1920 --height 1080

# Apps
peekaboo app list | launch Safari | quit Safari | relaunch Safari | switch Safari

# Virtual desktops
peekaboo space list | switch 2 | move-window --app Safari --space 3
```

## Menu, Menubar, Dock, Dialog

```bash
# Menus
peekaboo menu list --app Safari | list-all --app Safari
peekaboo menu click --app Safari --menu "File" --item "New Window"
peekaboo menu click-extra --app Safari --item "Extensions"

# Menubar
peekaboo menubar list | click --name "Wi-Fi" | click --index 3

# Dock
peekaboo dock list | launch Safari | right-click Safari | hide | show

# Dialogs
peekaboo dialog list | click --button "OK" | input --text "filename.txt"
peekaboo dialog file --path ~/Documents/file.txt | dismiss
```

## Agent (Natural Language)

```bash
peekaboo agent "Open Safari and navigate to github.com"
peekaboo agent --model gpt-5.1 "Find and click the login button"
peekaboo agent --dry-run "Close all Safari windows"               # Show plan only
peekaboo agent --resume                                           # Resume session
peekaboo agent --max-steps 10 "Complete the checkout process"
```

## Utility

```bash
peekaboo sleep --duration 1000                    # Delay (ms)
peekaboo clean --all-snapshots | --older-than 7d
peekaboo tools --verbose --json-output
peekaboo config init | show | add openai | login anthropic | models
```

## MCP Server Configuration

Add to AI assistant config (Claude Desktop `Developer > Edit Config`, OpenCode, or Cursor):

```json
{
  "mcpServers": {
    "peekaboo": {
      "command": "npx",
      "args": ["-y", "@steipete/peekaboo"],
      "env": { "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.1,anthropic/claude-opus-4-6" }
    }
  }
}
```

OpenCode adds `"type": "stdio"` to the same structure.

## AI Providers

| Provider | Models | Env Var |
|----------|--------|---------|
| OpenAI | GPT-5.1, GPT-4.1, GPT-4o | `OPENAI_API_KEY` |
| Anthropic | Claude 4.x | `ANTHROPIC_API_KEY` |
| xAI | Grok 4-fast | `XAI_API_KEY` |
| Google | Gemini 2.5 (pro/flash) | `GOOGLE_API_KEY` |
| Ollama | llama3.3, llava, glm-ocr, etc. | Local (no key) |

**Recommended**: OCR/document extraction: `ollama/glm-ocr` | General screen: `ollama/llava` or cloud | UI element detection: cloud (GPT-4o, Claude).

```bash
peekaboo config add openai
export PEEKABOO_AI_PROVIDERS="openai/gpt-5.1,anthropic/claude-opus-4-6"
# Ollama local
brew install ollama && ollama pull llava && ollama pull glm-ocr
peekaboo image --mode window --app Preview --analyze "Extract all text" --model ollama/glm-ocr
```

**GLM-OCR** recommended for OCR-heavy tasks. See `tools/ocr/glm-ocr.md` for standalone OCR workflows.

## Workflow: Form Filling

```bash
SNAPSHOT=$(peekaboo see --app Safari --json-output | jq -r '.data.snapshot_id')
peekaboo click --on "Email" --snapshot "$SNAPSHOT" && peekaboo type --text "user@example.com"
peekaboo click --on "Password" --snapshot "$SNAPSHOT" && peekaboo type --text "secure-password"
peekaboo click --on "Submit" --snapshot "$SNAPSHOT"
```

## When to Use Peekaboo vs Other Tools

| Use case | Tool |
|----------|------|
| macOS native app automation, screen capture with AI, menu bar/dock/spaces | **Peekaboo** |
| Cross-platform web automation | agent-browser, Playwright, Stagehand |
| Linux/Windows | Any cross-platform tool |

## Troubleshooting

```bash
# Permissions
peekaboo permissions status
tccutil reset ScreenCapture com.steipete.Peekaboo
tccutil reset Accessibility com.steipete.Peekaboo && peekaboo permissions grant

# MCP connection
npx -y @steipete/peekaboo --help && node --version  # Requires 22+
lsof -i :3000

# Snapshots
peekaboo clean --all-snapshots && ls -la ~/.peekaboo/snapshots/
```
