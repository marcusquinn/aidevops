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

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Automate iOS Simulators using Apple's Accessibility APIs and HID
- **Install**: `brew install cameroncooke/axe/axe`
- **Architecture**: Single binary CLI, no server or daemon required
- **Requirements**: macOS with Xcode and iOS Simulator
- **GitHub**: https://github.com/cameroncooke/AXe (MIT, by XcodeBuildMCP author)

**Why AXe over idb**: Single binary (no client/server), focused on UI automation,
no external dependencies, complete HID coverage plus gesture presets and timing controls.

<!-- AI-CONTEXT-END -->

## Core Commands

All commands require `--udid SIMULATOR_UDID`. Get UDIDs with `axe list-simulators`.

### Touch, Gestures, and Input

```bash
# Tap by coordinates, accessibility ID, or label
axe tap -x 100 -y 200 --udid $UDID
axe tap --id "Safari" --udid $UDID
axe tap --label "Submit" --udid $UDID
# Swipe with configurable duration and delta
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --udid $UDID
# Gesture presets: scroll-up/down/left/right,
#   swipe-from-{left,right,top,bottom}-edge
axe gesture scroll-down --udid $UDID
axe gesture swipe-from-left-edge --udid $UDID
# Text input (direct, stdin, or file)
axe type 'Hello World!' --udid $UDID
echo "text" | axe type --stdin --udid $UDID
```

### Hardware Buttons and Timing

```bash
# Buttons: home, lock, side-button, siri, apple-pay
axe button home --udid $UDID
axe button lock --duration 2.0 --udid $UDID
# Pre/post delays on any touch/gesture command (seconds)
axe tap -x 100 -y 200 --pre-delay 1.0 --post-delay 0.5 --udid $UDID
```

### Screenshots, Video, and Accessibility

```bash
axe screenshot --output ~/Desktop/capture.png --udid $UDID    # path printed to stdout
axe record-video --udid $UDID --fps 15 --output recording.mp4 # Ctrl+C to stop
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
| Video / a11y tree | Native H.264, `describe-ui` | Not available / via simctl |
| Best for | Scripts, CI, pipelines | Direct AI tool calling |

## Integration with XcodeBuildMCP

AXe pairs with XcodeBuildMCP for build-then-test workflows:

1. **Build** with XcodeBuildMCP (compile, install to simulator)
2. **Automate** with AXe (tap, type, swipe, verify)
3. **Inspect** with `describe-ui` and **capture** with `screenshot`/`record-video`

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
