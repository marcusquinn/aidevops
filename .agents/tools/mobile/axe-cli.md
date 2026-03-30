---
description: AXe - CLI tool for iOS Simulator automation via Apple's Accessibility APIs and HID
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

# AXe - iOS Simulator Automation CLI

## Quick Reference

- **Install**: `brew install cameroncooke/axe/axe`
- **Requirements**: macOS with Xcode and iOS Simulator
- **GitHub**: https://github.com/cameroncooke/AXe (1.2k stars, MIT, by XcodeBuildMCP author)
- **vs idb**: Single binary (no client/server/daemon), complete HID coverage, gesture presets, timing controls

## Core Commands

All commands require `--udid SIMULATOR_UDID`. Get UDIDs: `axe list-simulators`.

### Touch, Gestures, and Input

```bash
axe tap -x 100 -y 200 --udid $UDID                # coordinates
axe tap --id "Safari" --udid $UDID                  # accessibility ID
axe tap --label "Submit" --udid $UDID               # label
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --udid $UDID
# Presets: scroll-up/down/left/right, swipe-from-{left,right,top,bottom}-edge
axe gesture scroll-down --udid $UDID
axe type 'Hello World!' --udid $UDID                # direct text input
echo "text" | axe type --stdin --udid $UDID         # stdin
# Timing: --pre-delay / --post-delay (seconds) on any touch/gesture
axe tap -x 100 -y 200 --pre-delay 1.0 --post-delay 0.5 --udid $UDID
```

### Keyboard and Buttons

```bash
# Key press by HID keycode (40=Enter, 42=Backspace)
axe key 40 --udid $UDID
axe key 42 --duration 1.0 --udid $UDID
# Key sequences (type "hello" by keycodes)
axe key-sequence --keycodes 11,8,15,15,18 --udid $UDID
# Combos: modifier + key (227=Cmd, 225=Shift)
axe key-combo --modifiers 227 --key 4 --udid $UDID          # Cmd+A
axe key-combo --modifiers 227,225 --key 4 --udid $UDID      # Cmd+Shift+A
# Hardware buttons: home, lock, side-button, siri, apple-pay
axe button home --udid $UDID
axe button lock --duration 2.0 --udid $UDID
```

### Screenshots, Video, and Accessibility

```bash
axe screenshot --output ~/Desktop/capture.png --udid $UDID
# Video recording (H.264 MP4, Ctrl+C to stop); flags: --fps, --quality, --scale
axe record-video --udid $UDID --fps 15 --output recording.mp4
# Stream formats: mjpeg, ffmpeg, raw, bgra
axe stream-video --udid $UDID --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 output.mp4
# Accessibility tree (full screen or specific point)
axe describe-ui --udid $UDID
axe describe-ui --point 100,200 --udid $UDID
```

## AXe CLI vs iOS Simulator MCP

| Aspect | AXe CLI | iOS Simulator MCP |
|--------|---------|-------------------|
| Interface | CLI (scriptable) | MCP server (AI-native) |
| Dependencies | Single binary | Node.js + MCP runtime |
| Tap targeting | Coordinates, ID, label | Coordinates only |
| Gesture presets | 8 built-in | Manual swipe params |
| Video | H.264 recording, 4 stream formats | `record_video` / `stop_recording` |
| Accessibility | `describe-ui` (full/point) | `ui_describe_all`, `ui_describe_point` |
| App management | Not available | `install_app`, `launch_app` |
| Best for | Scripts, CI, pipelines | Direct AI tool calling |

## Common Patterns

```bash
# Accessibility audit: dump UI tree + screenshot
axe describe-ui --udid "$UDID" > ui-tree.txt
axe screenshot --output ui-state.png --udid "$UDID"
# UI flow: tap, scroll, verify
axe tap --label "Settings" --pre-delay 0.5 --udid "$UDID"
axe gesture scroll-down --post-delay 0.5 --udid "$UDID"
axe describe-ui --udid "$UDID"
```

## Related

- `tools/mobile/xcodebuild-mcp.md` - Build automation (same author)
- `tools/mobile/ios-simulator-mcp.md` - MCP-based simulator control
- `tools/mobile/maestro.md` - Mobile UI testing framework
