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

<!-- AI-CONTEXT-START -->

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
5. `screenshot` / `snapshot_ui` -- verify UI state (returns view hierarchy with coordinates)
6. `maestro test flows/login.yaml` -- E2E tests on running simulator

## Tool Groups (76 tools, 15 workflow groups)

Only simulator tools enabled by default. Use `manage-workflows` to enable other groups.

| Group | Key Tools |
|-------|-----------|
| **simulator** | `build_sim`, `build_run_sim`, `test_sim`, `launch_app_sim` |
| **device** | `build_device`, `test_device`, `install_app_device`, `launch_app_device` — requires code signing |
| **macos** | `build_macos`, `build_run_macos`, `test_macos`, `launch_mac_app` |
| **swift-package** | `swift_package_build`, `swift_package_test`, `swift_package_run` — Swift Macros validation skipped |
| **debugging** | `debug_attach_sim`, `debug_breakpoint_add`, `debug_variables`, `debug_stack` |
| **ui-automation** | `tap`, `swipe`, `type_text`, `screenshot`, `snapshot_ui` |
| **simulator-management** | `boot_sim`, `list_sims`, `set_sim_location`, `erase_sims` |
| **logging** | `start_sim_log_cap`, `stop_sim_log_cap` |
| **project-discovery** | `discover_projs`, `list_schemes`, `show_build_settings` |
| **project-scaffolding** | `scaffold_ios_project`, `scaffold_macos_project` |
| **session-management** | `session_set_defaults`, `sync_xcode_defaults` — persists scheme/simulator/device across calls |
| **doctor** | `doctor` — environment diagnostics |

## MCP Configuration

**Claude Code:** `claude mcp add XcodeBuildMCP -- npx -y xcodebuildmcp@beta mcp`

**JSON** (Cursor, VS Code, Claude Desktop, OpenCode):

```json
{ "mcpServers": { "XcodeBuildMCP": { "command": "npx", "args": ["-y", "xcodebuildmcp@beta", "mcp"] } } }
```

## Related

- `tools/mobile/minisim.md` -- Simulator/emulator GUI launcher (MiniSim)
- `tools/browser/playwright.md` -- Cross-platform testing (web)
- `services/hosting/localhost.md` -- Local dev environment
- **Maestro** -- E2E UI test flows; run after `build_run_sim`
- **iOS Simulator MCP** -- Complementary simulator control
- **AXe** -- Accessibility testing; use with `snapshot_ui` output
