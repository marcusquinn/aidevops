---
description: iOS Simulator MCP - AI-driven iOS simulator interaction via MCP
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

# iOS Simulator MCP - Simulator Interaction Server

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: MCP server for direct iOS simulator interaction (tap, swipe, type, screenshot)
- **Install**: `npx -y ios-simulator-mcp` (runs via MCP, no global install needed)
- **Claude Code**: `claude mcp add ios-simulator npx ios-simulator-mcp`
- **GitHub**: https://github.com/joshuayoes/ios-simulator-mcp (1.6k stars, MIT)
- **Featured in**: [Anthropic's Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)

**Requirements**: macOS, Xcode with iOS simulators, Node.js, Facebook [IDB](https://fbidb.io/) (`brew tap facebook/fb && brew install idb-companion`)

<!-- AI-CONTEXT-END -->

## MCP Tools

| Tool | Description |
|------|-------------|
| `ui_tap` | Tap at x,y coordinates (optional duration for long-press) |
| `ui_swipe` | Swipe from start to end coordinates |
| `ui_type` | Input text into the focused field (ASCII) |
| `ui_view` | Get compressed screenshot of current screen |
| `screenshot` | Save screenshot to file (png, jpeg, tiff, bmp, gif) |
| `record_video` | Record simulator screen (h264/hevc codec) |
| `stop_recording` | Stop active video recording |
| `ui_describe_all` | Describe all accessibility elements on screen |
| `ui_describe_point` | Describe accessibility element at x,y |
| `install_app` | Install .app or .ipa bundle on simulator |
| `launch_app` | Launch app by bundle ID (e.g., `com.apple.mobilesafari`) |
| `get_booted_sim_id` | Get UDID of the currently booted simulator |
| `open_simulator` | Open the Simulator application |

## Configuration

```bash
# Claude Code
claude mcp add ios-simulator npx ios-simulator-mcp
```

```json
// OpenCode / Cursor (~/.config/opencode/mcp.json or ~/.cursor/mcp.json)
{
  "mcpServers": {
    "ios-simulator": {
      "command": "npx",
      "args": ["-y", "ios-simulator-mcp"]
    }
  }
}
```

**Environment variables**: `IOS_SIMULATOR_MCP_DEFAULT_OUTPUT_DIR` (screenshot/video output, default `~/Downloads`), `IOS_SIMULATOR_MCP_FILTERED_TOOLS` (comma-separated tools to disable), `IOS_SIMULATOR_MCP_IDB_PATH` (custom IDB path).

## AI-Assisted QA Patterns

Use these prompts after implementing a feature to validate behaviour:

- **Verify UI elements**: "Describe all accessibility elements on the current screen"
- **Confirm text input**: "Enter 'Hello World' into the text field and confirm the input"
- **Validate tap response**: "Tap at x=250, y=400 and verify the expected element responds"
- **Validate gestures**: "Swipe from x=150, y=600 to x=150, y=100 and confirm scroll"
- **Visual check**: "Take a screenshot and save to qa-check.png"
- **Record flow**: "Record video while I walk through the onboarding flow"

## Integration with Other Tools

| Tool | Role | Integration |
|------|------|-------------|
| **XcodeBuildMCP** | Build the app | Build with XcodeBuildMCP, then `install_app` + `launch_app` via this MCP |
| **Maestro** | E2E test flows | Maestro for scripted repeatable flows; this MCP for ad-hoc AI-driven QA |
| **MiniSim** | Simulator launcher | MiniSim manages simulator lifecycle; this MCP interacts with running sims |

## Comparison: ios-simulator-mcp vs AXe CLI (t100)

Both enable simulator interaction but take different approaches:

| Aspect | ios-simulator-mcp | AXe CLI |
|--------|-------------------|---------|
| **Interface** | MCP server (tool calls) | CLI commands |
| **AI integration** | Native MCP - AI calls tools directly | Requires bash wrapping |
| **Accessibility** | `ui_describe_all`, `ui_describe_point` | Full accessibility tree queries |
| **Video** | `record_video` / `stop_recording` | Not available |
| **App management** | `install_app`, `launch_app` | Not available |
| **Best for** | AI-driven QA, interactive testing | Accessibility auditing, tree inspection |

## Troubleshooting

- **IDB not found**: `brew tap facebook/fb && brew install idb-companion`
- **No booted simulator**: `xcrun simctl boot "iPhone 16 Pro"` or use MiniSim
- **Security**: Use v1.3.3+ (command injection fix in earlier versions)

## Related Tools

- `tools/mobile/minisim.md` - Simulator launcher and lifecycle management
