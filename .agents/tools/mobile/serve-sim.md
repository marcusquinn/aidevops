---
description: serve-sim - stream and control Apple Simulators from a browser or AI agent
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# serve-sim - Apple Simulator Browser Preview

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Stream a booted iOS, iPad, or Apple Watch Simulator to a browser and drive it from CLI/agent commands.
- **Install**: `npm install -g serve-sim` or run ad hoc with `npx serve-sim`; Bun is not required to run the CLI.
- **Setup**: `./setup.sh` offers this on supported local Macs after MiniSim.
- **Requirements**: macOS on Apple Silicon, Xcode command-line tools (`xcrun simctl`), a maintained Node.js LTS release (Node.js 20+), and at least one booted Apple Simulator.
- **GitHub**: https://github.com/EvanBacon/serve-sim (Apache-2.0)

```bash
serve-sim                         # Preview UI at http://localhost:3200
serve-sim --detach -q             # Start background preview and return JSON with url/streamUrl
serve-sim --host 0.0.0.0          # Expose preview on a trusted LAN
serve-sim --codec mjpeg           # Pin stream codec when H.264 is unavailable
serve-sim --list -q               # List running simulator streams
serve-sim tap 0.5 0.9             # Tap normalized screen coordinates
serve-sim button home             # Send hardware button
serve-sim type "hello"            # Type into focused field
serve-sim --kill                  # Stop stream(s)
```

Use `serve-sim` when the user needs a visible, browser-shareable simulator surface. Pair it with `agent-device`, `ios-simulator-mcp`, or `maestro` when the task needs accessibility refs, MCP tool calls, or repeatable E2E flows. Current upstream builds serve capture, accessibility, and HID input through an in-process native addon instead of a separate `serve-sim-bin` helper, so malformed browser input should be ignored rather than crash the preview server. The preview defaults to H.264 when available and can switch or auto-downgrade to MJPEG when hardware decoding is unstable during screen recording; use `--codec <auto|mjpeg>` when the host must pin stream compatibility. Recent upstream versions also use incremental MJPEG and AVCC buffering plus paged simulator-grid loading, which keeps large multi-device catalogs and long recording sessions responsive.

<!-- AI-CONTEXT-END -->

## When to Use

| Need | Use |
|------|-----|
| Show a simulator in a browser or preview pane | `serve-sim --detach -q`, surface the `url` |
| Let humans and agents share the same local/LAN/tunneled simulator view | `serve-sim` preview UI |
| Drive low-level gestures, buttons, keyboard toggles, rotation, typing, memory warnings | `serve-sim gesture/button/type/rotate/memory-warning` |
| Test camera-dependent flows | `serve-sim camera <bundle-id> --file/--webcam` |
| Read simulator logs in browser-based agent tooling | `serve-sim` preview UI/log forwarding |

Do **not** use it for Android emulators, real iOS hardware, building/installing apps, or repeatable cross-platform flows where `maestro` is a better fit.

## Tool Decision

| Tool | Best For |
|------|----------|
| **serve-sim** | Browser-visible Apple Simulator streaming, shared review, camera injection, browser/agent control channel |
| `agent-device` | AI-driven interaction with accessibility refs on iOS and Android |
| `ios-simulator-mcp` | MCP-native iOS simulator tap/swipe/type/screenshot/install/launch |
| `maestro` | Human-authored YAML E2E flows on iOS and Android |
| `minisim` | Launching and managing simulator/emulator lifecycle from a menu bar |

## Core Commands

| Goal | Command | Notes |
|------|---------|-------|
| Start preview | `serve-sim [device...]` | Default preview server: `http://localhost:3200` |
| Start LAN preview | `serve-sim --host 0.0.0.0 [device...]` | Trusted networks only; exposes the browser control surface |
| Start daemon | `serve-sim --detach -q [device...]` | JSON output is safest for agents |
| Stream only | `serve-sim --no-preview [device...]` | Foreground stream without React preview UI |
| List streams | `serve-sim --list -q` | Use `-q` for machine-readable output |
| Force compatibility stream | `serve-sim --codec mjpeg [device...]`, open the preview with `?codec=mjpeg`, or use Stream → Codec | Use MJPEG if H.264/WebCodecs stutters or fails while recording |
| Stop streams | `serve-sim --kill [device]` | Stop all streams or one device stream |
| Tap | `serve-sim tap 0.5 0.9 [-d udid]` | Normalized 0..1 screen coordinates; prefer this over raw gesture JSON for plain taps |
| Gesture | `serve-sim gesture '<json>' [-d udid]` | Use documented JSON shape; avoid guessing coordinates |
| Button | `serve-sim button home [-d udid]` | Hardware/home/app-switcher style controls |
| Type | `serve-sim type "text" [-d udid]` | Also supports `--stdin` and `--file <path>` |
| Toggle software keyboard | Press `Cmd+K` in the preview | Mirrors Simulator's software keyboard toggle without changing hardware-keyboard state |
| Rotate | `serve-sim rotate landscape_left [-d udid]` | portrait, portrait_upside_down, landscape_left, landscape_right |
| Memory warning | `serve-sim memory-warning [-d udid]` | Simulator memory-pressure test |
| CoreAnimation | `serve-sim ca-debug slow-animations on [-d udid]` | blended, copies, misaligned, offscreen, slow-animations |
| UI settings | `serve-sim ui --help` | Get or set simulator-wide UI options exposed by upstream |
| Permissions | `serve-sim permissions` | Manage app permissions with the upstream parser |
| Camera injection | `serve-sim camera <bundle-id> --file <path>` | Also supports placeholder/webcam sources, `camera switch`, `camera mirror`, `camera status`, `--list-webcams`, and `--stop-webcam` |

## Agent Workflow

1. Verify prerequisites: `uname -s`, `uname -m`, `node --version`, and `xcrun simctl list devices booted`.
2. Start the preview with `serve-sim --detach -q`.
3. Parse only JSON/quiet output; do not scrape human-readable output.
4. Surface the returned `url` to the user. If the current runtime exposes a preview/open-url tool, pass the URL there too.
5. Use `agent-device snapshot` or `ios-simulator-mcp` for accessibility-aware targeting; use `serve-sim` for the shared visual stream and simulator-specific commands.
6. If the browser preview stutters, drops frames, or reports an H.264 decoder failure while screen recording, restart with `serve-sim --codec mjpeg`, switch the Stream → Codec control to MJPEG, or append `?codec=mjpeg` to the preview URL.
7. For plain coordinate taps, use `serve-sim tap <x> <y>` with normalized 0..1 values; reserve `serve-sim gesture '<json>'` for drag, swipe, and multi-touch shapes.
8. Clean up with `serve-sim --kill` unless the user asks to keep the simulator stream running.

## Expo / Dev Server Embedding

`serve-sim/middleware` can mount the preview under an existing Connect-style server, including Expo Metro. This is useful when a mobile dev server should expose the simulator at a stable path such as `/.sim`. Recent upstream versions route the preview, same-origin helper endpoints, and WebKit DevTools proxying through the in-process server when the host wires HTTP upgrade handling, so remote viewers only need the preview server port. The device grid is paged by default and exposes total/loaded counts; searching intentionally loads the full catalog, then clearing search resets to the paged window.

## Upstream Agent Skill

The upstream repository ships an Agent Skill under `skills/serve-sim`. For runtimes that support the Agent Skills standard, install it with the host's native skill/plugin installer:

```bash
# Claude Code plugin marketplace (current singular `/plugin` command flow)
/plugin marketplace add EvanBacon/serve-sim
/plugin install serve-sim

# Other Agent Skills hosts
npx skills add EvanBacon/serve-sim
# or
bunx add-skill EvanBacon/serve-sim
```

aidevops keeps this native guide so mobile-testing tasks route to `serve-sim` even when the upstream skill is not installed.

## Troubleshooting

- **Unsupported host**: The native simulator addon is Apple Silicon only. Intel Macs should use other simulator tools.
- **No simulator**: Boot one first with Xcode Simulator, MiniSim, or `xcrun simctl boot <device>`.
- **Node too old**: Upgrade to a maintained Node.js LTS release (Node.js 20+) before running the CLI.
- **Port collision**: Stop stale streams with `serve-sim --kill`.
- **H.264/WebCodecs instability**: Use `serve-sim --codec mjpeg`, the Stream → Codec picker, or append `?codec=mjpeg` to the preview URL; recent versions auto-downgrade fatal AVCC decoder failures to MJPEG.
- **Camera injection**: Requires macOS 14+ and a simulator app bundle ID.

## Related

- `tools/mobile/agent-device.md` — AI-driven mobile automation
- `tools/mobile/ios-simulator-mcp.md` — MCP simulator interaction
- `tools/mobile/maestro.md` — repeatable mobile E2E flows
- `tools/mobile/minisim.md` — simulator/emulator launcher
- `tools/mobile/app-dev-testing.md` — full mobile testing strategy
