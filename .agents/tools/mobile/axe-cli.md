---
description: AXe - CLI tool for iOS Simulator automation via Apple's Accessibility APIs and HID
mode: subagent
tools:
  read: true
  bash: true
---

# AXe - iOS Simulator Automation CLI

- **Install**: `brew install cameroncooke/axe/axe`
- **Requirements**: macOS + Xcode + iOS Simulator
- **GitHub**: https://github.com/cameroncooke/AXe (MIT, by XcodeBuildMCP author)
- **vs idb**: Single binary (no daemon), complete HID coverage, gesture presets, timing controls
- All commands require `--udid $UDID`. Get UDIDs: `axe list-simulators`.

## Commands

```bash
# Touch & gestures
axe tap -x 100 -y 200 --udid $UDID                # coordinates
axe tap --id "Safari" --udid $UDID                  # accessibility ID
axe tap --label "Submit" --udid $UDID               # label
axe tap -x 100 -y 200 --pre-delay 1.0 --post-delay 0.5 --udid $UDID  # timing on any touch/gesture
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --udid $UDID
axe gesture scroll-down --udid $UDID               # presets: scroll-up/down/left/right, swipe-from-{left,right,top,bottom}-edge
axe type 'Hello World!' --udid $UDID               # direct text; echo "text" | axe type --stdin --udid $UDID

# Keyboard & buttons
axe key 40 --udid $UDID                            # HID keycode (40=Enter, 42=Backspace); --duration N for hold
axe key-sequence --keycodes 11,8,15,15,18 --udid $UDID         # type "hello" by keycodes
axe key-combo --modifiers 227 --key 4 --udid $UDID             # Cmd+A (227=Cmd, 225=Shift)
axe key-combo --modifiers 227,225 --key 4 --udid $UDID         # Cmd+Shift+A
axe button home --udid $UDID                       # hardware: home, lock, side-button, siri, apple-pay; --duration N

# Media & UI inspection
axe screenshot --output ~/Desktop/capture.png --udid $UDID
axe record-video --udid $UDID --fps 15 --output recording.mp4  # H.264 MP4; flags: --fps, --quality, --scale
axe stream-video --udid $UDID --fps 30 --format ffmpeg | \     # stream formats: mjpeg, ffmpeg, raw, bgra
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 output.mp4
axe describe-ui --udid $UDID                       # accessibility tree (full screen or --point 100,200)
```

## Common Patterns

```bash
# Accessibility audit: dump UI tree + screenshot
axe describe-ui --udid "$UDID" > ui-tree.txt && axe screenshot --output ui-state.png --udid "$UDID"
# UI flow: tap, scroll, verify
axe tap --label "Settings" --pre-delay 0.5 --udid "$UDID" && axe gesture scroll-down --post-delay 0.5 --udid "$UDID"
axe describe-ui --udid "$UDID"
```

## AXe CLI vs iOS Simulator MCP

| Aspect | AXe CLI | iOS Simulator MCP |
|--------|---------|-------------------|
| Dependencies | Single binary | Node.js + MCP runtime |
| Tap targeting | Coordinates, ID, label | Coordinates only |
| Gesture presets | 8 built-in | Manual swipe params |
| Video | H.264 recording, 4 stream formats | `record_video` / `stop_recording` |
| Accessibility | `describe-ui` (full/point) | `ui_describe_all`, `ui_describe_point` |
| App management | Not available | `install_app`, `launch_app` |
| Best for | Scripts, CI, pipelines | Direct AI tool calling |

## Related

- `tools/mobile/xcodebuild-mcp.md` - Build automation (same author)
- `tools/mobile/ios-simulator-mcp.md` - MCP-based simulator control
- `tools/mobile/maestro.md` - Mobile UI testing framework
