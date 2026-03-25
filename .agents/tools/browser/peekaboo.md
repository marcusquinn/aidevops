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
SNAPSHOT=$(peekaboo see --app Safari --json-output | jq -r '.data.snapshot_id')
peekaboo click --on "Reload this page" --snapshot "$SNAPSHOT"

# Natural language automation
peekaboo agent "Open Notes and create a TODO list with three items"
```

<!-- AI-CONTEXT-END -->

## Installation

```bash
# CLI + App
brew install steipete/tap/peekaboo

# Verify
peekaboo --version
peekaboo permissions status
```

## Permissions Setup

```bash
# Check and grant
peekaboo permissions status
peekaboo permissions grant  # Opens System Preferences
```

- **Screen Recording**: System Preferences > Privacy & Security > Screen Recording
- **Accessibility**: System Preferences > Privacy & Security > Accessibility

## Core Commands

### Image Capture

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

### See (Capture + Annotate)

Captures UI and returns snapshot with element IDs for subsequent actions:

```bash
peekaboo see --app Safari --json-output    # App UI with element annotations
peekaboo see --mode screen --json-output   # Full screen with annotations
# Returns snapshot_id for use with click/type commands
```

### Click

```bash
peekaboo click --on @e42 --snapshot "$SNAPSHOT_ID"          # By element ID
peekaboo click --on "Submit" --snapshot "$SNAPSHOT_ID"       # By label
peekaboo click --x 100 --y 200                               # By coordinates
peekaboo click --on "Login" --snapshot "$SNAPSHOT_ID" --wait 2000  # With wait
```

### Type

```bash
peekaboo type --text "Hello, World!"
peekaboo type --text "new value" --clear          # Clear field first
peekaboo type --text "slow typing" --delay-ms 100
```

### Press / Hotkey / Scroll / Swipe / Drag / Move

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

### Window Management

```bash
peekaboo window list
peekaboo window focus --app Safari
peekaboo window move --app Safari --x 100 --y 100
peekaboo window resize --app Safari --width 1200 --height 800
peekaboo window set-bounds --app Safari --x 0 --y 0 --width 1920 --height 1080
```

### App Control

```bash
peekaboo app list
peekaboo app launch Safari
peekaboo app quit Safari
peekaboo app relaunch Safari
peekaboo app switch Safari
```

### Space (Virtual Desktops)

```bash
peekaboo space list
peekaboo space switch 2
peekaboo space move-window --app Safari --space 3
```

### Menu Interaction

```bash
peekaboo menu list --app Safari
peekaboo menu list-all --app Safari
peekaboo menu click --app Safari --menu "File" --item "New Window"
peekaboo menu click-extra --app Safari --item "Extensions"
```

### Menubar / Dock / Dialog

```bash
peekaboo menubar list
peekaboo menubar click --name "Wi-Fi"
peekaboo menubar click --index 3

peekaboo dock list
peekaboo dock launch Safari
peekaboo dock right-click Safari
peekaboo dock hide && peekaboo dock show

peekaboo dialog list
peekaboo dialog click --button "OK"
peekaboo dialog input --text "filename.txt"
peekaboo dialog file --path ~/Documents/file.txt
peekaboo dialog dismiss
```

### Agent (Natural Language)

```bash
peekaboo agent "Open Safari and navigate to github.com"
peekaboo agent --model gpt-5.1 "Find and click the login button"
peekaboo agent --dry-run "Close all Safari windows"   # Show plan without executing
peekaboo agent --resume                               # Resume previous session
peekaboo agent --max-steps 10 "Complete the checkout process"
```

### Utility

```bash
peekaboo sleep --duration 1000                        # Delay (ms)
peekaboo clean --all-snapshots
peekaboo clean --older-than 7d
peekaboo tools --verbose --json-output
peekaboo config init && peekaboo config show
peekaboo config add openai && peekaboo config login anthropic
peekaboo config models
```

## MCP Server Configuration

Add to your AI assistant config. Key env var: `PEEKABOO_AI_PROVIDERS`.

**Claude Desktop** (`Developer > Edit Config`):

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

**OpenCode** (`~/.config/opencode/opencode.json`) and **Cursor** (MCP settings) use the same structure with `"type": "stdio"` for OpenCode.

## AI Providers

| Provider | Models | Environment Variable |
|----------|--------|---------------------|
| OpenAI | GPT-5.1, GPT-4.1, GPT-4o | `OPENAI_API_KEY` |
| Anthropic | Claude 4.x | `ANTHROPIC_API_KEY` |
| xAI | Grok 4-fast | `XAI_API_KEY` |
| Google | Gemini 2.5 (pro/flash) | `GOOGLE_API_KEY` |
| Ollama | llama3.3, llava, glm-ocr, etc. | Local (no key needed) |

**Recommended by task:**

| Task | Model |
|------|-------|
| OCR / Document text extraction | `ollama/glm-ocr` |
| General screen understanding | `ollama/llava` or cloud |
| UI element detection | Cloud (GPT-4o, Claude) |

```bash
# Configure provider
peekaboo config add openai
export PEEKABOO_AI_PROVIDERS="openai/gpt-5.1,anthropic/claude-opus-4-6"

# Ollama local models
brew install ollama
ollama pull llava && ollama pull glm-ocr
peekaboo image --mode window --app Preview --analyze "Extract all text" --model ollama/glm-ocr
```

**GLM-OCR** is recommended for OCR-heavy tasks. See `tools/ocr/glm-ocr.md` for standalone OCR workflows.

## Workflow Patterns

### Automated Form Filling

```bash
SNAPSHOT=$(peekaboo see --app Safari --json-output | jq -r '.data.snapshot_id')
peekaboo click --on "Email" --snapshot "$SNAPSHOT"
peekaboo type --text "user@example.com"
peekaboo click --on "Password" --snapshot "$SNAPSHOT"
peekaboo type --text "secure-password"
peekaboo click --on "Submit" --snapshot "$SNAPSHOT"
```

### Multi-Window Workflow

```bash
peekaboo window list --json-output
peekaboo window focus --app Safari --title "GitHub"
peekaboo window set-bounds --app Safari --x 0 --y 0 --width 960 --height 1080
peekaboo window set-bounds --app "VS Code" --x 960 --y 0 --width 960 --height 1080
```

## When to Use Peekaboo vs Other Tools

| Use case | Tool |
|----------|------|
| macOS native app automation | **Peekaboo** |
| Screen capture with AI analysis | **Peekaboo** |
| Menu bar, dock, virtual desktops | **Peekaboo** |
| Cross-platform web automation | agent-browser, Playwright, Stagehand |
| Linux/Windows | Any cross-platform tool |

## Troubleshooting

```bash
# Permission issues
peekaboo permissions status
tccutil reset ScreenCapture com.steipete.Peekaboo
tccutil reset Accessibility com.steipete.Peekaboo
peekaboo permissions grant

# MCP connection issues
npx -y @steipete/peekaboo --help
lsof -i :3000
node --version  # Requires 22+

# Snapshot issues
peekaboo clean --all-snapshots
ls -la ~/.peekaboo/snapshots/
```

## Resources

- **GitHub**: https://github.com/steipete/Peekaboo
- **Website**: https://peekaboo.boo
- **npm**: https://www.npmjs.com/package/@steipete/peekaboo
- **Docs**: https://github.com/steipete/Peekaboo/tree/main/docs
- **License**: MIT
