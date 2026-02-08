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

**Key Capabilities**:
- Build iOS/macOS apps for simulators and physical devices
- Run XCTest suites and report results to the agent
- Deploy and launch apps on simulators and connected devices
- LLDB debugger attachment with breakpoints and variable inspection
- UI automation (tap, swipe, type, screenshots, accessibility snapshots)
- Swift Package Manager build/test/run
- Scaffold new iOS/macOS projects from templates
- Simulator management (boot, erase, location, appearance, status bar)

<!-- AI-CONTEXT-END -->

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
| **logging** | `start_sim_log_cap`, `stop_sim_log_cap` | Log capture for debugging |
| **project-discovery** | `discover_projs`, `list_schemes`, `show_build_settings` | Project analysis |
| **project-scaffolding** | `scaffold_ios_project`, `scaffold_macos_project` | New project creation |
| **session-management** | `session_set_defaults`, `sync_xcode_defaults` | Persistent session config |
| **doctor** | `doctor` | Environment diagnostics |

Only simulator tools are enabled by default. Use `manage-workflows` to enable device, macOS, debugging, or other groups.

## Notes

- Device tools require code signing configured in Xcode
- Macro validation is skipped automatically to avoid Swift Macro build errors
- `snapshot_ui` returns view hierarchy with coordinates (useful for UI automation)
- Session defaults persist scheme/simulator/device across tool calls

## Integration with aidevops Mobile Stack

| Tool | Role | Combines With |
|------|------|---------------|
| **XcodeBuildMCP** | Build, test, deploy | Primary build tool |
| **Maestro** | E2E UI test flows | Run after `build_run_sim` |
| **iOS Simulator MCP** | Simulator control | Complementary sim management |
| **AXe** | Accessibility testing | Use with `snapshot_ui` output |
| **MiniSim** | Quick simulator launch | GUI launcher alternative |

### Typical Workflow

1. `discover_projs` - scan for .xcodeproj/.xcworkspace
2. `build_sim --scheme MyApp` - build for simulator
3. `test_sim --scheme MyApp` - run XCTest suite
4. `build_run_sim --scheme MyApp` - deploy and launch with logs
5. `screenshot` / `snapshot_ui` - verify UI state
6. `maestro test flows/login.yaml` - E2E tests on running simulator

## Related Tools

- `tools/mobile/minisim.md` - Simulator/emulator GUI launcher
- `tools/browser/playwright.md` - Cross-platform testing (web)
- `services/hosting/localhost.md` - Local dev environment
