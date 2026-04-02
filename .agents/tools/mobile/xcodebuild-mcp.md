---
description: XcodeBuildMCP - MCP server for Xcode build, test, and deployment via AI agents
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# XcodeBuildMCP - Xcode Integration for AI Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: MCP server + CLI providing xcodebuild tools for iOS/macOS development
- **Install**: `npx -y xcodebuildmcp@beta mcp` (MCP server mode)
- **CLI**: `npm install -g xcodebuildmcp@beta` then `xcodebuildmcp --help`
- **Requirements**: macOS 14.5+, Xcode 16+, Node.js 18+
- **GitHub**: https://github.com/cameroncooke/XcodeBuildMCP (4.1k stars, MIT)
- **Docs**: https://www.xcodebuildmcp.com

<!-- AI-CONTEXT-END -->

## Typical Workflow

1. `discover_projs` -- scan for .xcodeproj/.xcworkspace
2. `build_sim --scheme MyApp` -- build for simulator
3. `test_sim --scheme MyApp` -- run XCTest suite
4. `build_run_sim --scheme MyApp` -- deploy and launch with logs
5. `screenshot` / `snapshot_ui` -- verify UI state
6. `maestro test flows/login.yaml` -- E2E tests on running simulator

## Tool Groups (76 tools, 15 workflow groups)

| Group | Key Tools | Purpose |
|-------|-----------|---------|
| **simulator** | `build_sim`, `build_run_sim`, `test_sim`, `launch_app_sim` | iOS simulator build/test/run |
| **device** | `build_device`, `test_device`, `install_app_device`, `launch_app_device` | Physical device deployment |
| **macos** | `build_macos`, `build_run_macos`, `test_macos`, `launch_mac_app` | macOS app development |
| **swift-package** | `swift_package_build`, `swift_package_test`, `swift_package_run` | SPM project workflows |
| **debugging** | `debug_attach_sim`, `debug_breakpoint_add`, `debug_variables`, `debug_stack` | LLDB debugger integration |
| **ui-automation** | `tap`, `swipe`, `type_text`, `screenshot`, `snapshot_ui` | UI testing and interaction |
| **simulator-management** | `boot_sim`, `list_sims`, `set_sim_location`, `erase_sims` | Simulator lifecycle |
| **logging** | `start_sim_log_cap`, `stop_sim_log_cap` | Log capture |
| **project-discovery** | `discover_projs`, `list_schemes`, `show_build_settings` | Project analysis |
| **project-scaffolding** | `scaffold_ios_project`, `scaffold_macos_project` | New project creation |
| **session-management** | `session_set_defaults`, `sync_xcode_defaults` | Persistent session config |
| **doctor** | `doctor` | Environment diagnostics |

Only simulator tools enabled by default. Use `manage-workflows` to enable other groups.

## Notes

- **Device tools**: require code signing configured in Xcode.
- **Swift Macros**: validation skipped automatically to avoid build errors.
- **UI Automation**: `snapshot_ui` returns view hierarchy with coordinates.
- **Persistence**: Session defaults persist scheme/simulator/device across calls.

## MCP Configuration

### Claude Code

```bash
claude mcp add XcodeBuildMCP -- npx -y xcodebuildmcp@beta mcp
```

### JSON Config (Cursor, VS Code, Claude Desktop, OpenCode)

```json
{
  "mcpServers": {
    "XcodeBuildMCP": {
      "command": "npx",
      "args": ["-y", "xcodebuildmcp@beta", "mcp"]
    }
  }
}
```

## Mobile Stack Integration

| Tool | Role |
|------|------|
| **Maestro** | E2E UI test flows -- run after `build_run_sim` |
| **iOS Simulator MCP** | Complementary simulator control |
| **AXe** | Accessibility testing -- use with `snapshot_ui` output |
| **MiniSim** | GUI simulator/emulator launcher |

## Related

- `tools/mobile/minisim.md` -- Simulator/emulator GUI launcher
- `tools/browser/playwright.md` -- Cross-platform testing (web)
- `services/hosting/localhost.md` -- Local dev environment
