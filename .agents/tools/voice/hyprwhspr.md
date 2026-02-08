---
description: hyprwhspr - native speech-to-text dictation for Linux (Wayland)
mode: subagent
upstream_url: https://github.com/goodroot/hyprwhspr
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# hyprwhspr - Linux Speech-to-Text

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: System-wide speech-to-text dictation on Linux (Wayland)
- **Source**: [goodroot/hyprwhspr](https://github.com/goodroot/hyprwhspr) (MIT, 790+ stars)
- **Platform**: Linux only (Arch, Debian, Ubuntu, Fedora, openSUSE) with Wayland (Hyprland, GNOME, KDE, Sway)
- **Backends**: Parakeet TDT V3, Whisper (pywhispercpp), onnx-asr, ElevenLabs REST API, Realtime WebSocket
- **Default hotkey**: `Super+Alt+D` (toggle dictation)

**When to use**: Setting up voice dictation on Linux desktops, especially Arch/Omarchy with Hyprland. For macOS voice input, use the built-in Dictation or `voice-helper.sh talk` instead.

<!-- AI-CONTEXT-END -->

## Installation

### Arch Linux (AUR)

```bash
# Stable
yay -S hyprwhspr

# Bleeding edge
yay -S hyprwhspr-git

# Interactive setup (configures backend, models, services)
hyprwhspr setup
```

### Debian / Ubuntu

```bash
curl -fsSL https://raw.githubusercontent.com/goodroot/hyprwhspr/main/scripts/install-deps.sh | bash
git clone https://github.com/goodroot/hyprwhspr.git ~/hyprwhspr
cd ~/hyprwhspr && ./bin/hyprwhspr setup
```

### Fedora / openSUSE

```bash
curl -fsSL https://raw.githubusercontent.com/goodroot/hyprwhspr/main/scripts/install-deps.sh | bash
git clone https://github.com/goodroot/hyprwhspr.git ~/hyprwhspr
cd ~/hyprwhspr && ./bin/hyprwhspr setup
```

### Post-Install

Log out and back in for group permissions, then verify:

```bash
hyprwhspr status
hyprwhspr validate
```

## Usage

1. Press `Super+Alt+D` to start dictation (beep)
2. Speak naturally
3. Press `Super+Alt+D` again to stop (boop)
4. Text is auto-pasted into the active buffer

### Recording Modes

- **Toggle** (default): Press to start, press to stop
- **Push-to-talk**: Hold key to record, release to stop
- **Long-form**: Pause, resume, pause, then submit

## CLI Commands

| Command | Purpose |
|---------|---------|
| `hyprwhspr setup` | Interactive initial setup |
| `hyprwhspr setup auto` | Automated setup (flags: `--backend`, `--model`, `--no-waybar`) |
| `hyprwhspr config` | Manage configuration (init/show/edit) |
| `hyprwhspr status` | Overall status check |
| `hyprwhspr validate` | Validate installation |
| `hyprwhspr test` | Test microphone and backend end-to-end |
| `hyprwhspr model` | Manage models (download/list/status) |
| `hyprwhspr waybar` | Manage Waybar integration |
| `hyprwhspr mic-osd` | Manage microphone visualizer overlay |
| `hyprwhspr systemd` | Manage systemd services |
| `hyprwhspr keyboard` | Keyboard device management |
| `hyprwhspr backend` | Backend management (repair/reset) |
| `hyprwhspr uninstall` | Complete removal |

## Transcription Backends

| Backend | GPU Required | Speed | Quality | Notes |
|---------|-------------|-------|---------|-------|
| **Parakeet TDT V3** | Optional | Fast | High | NVIDIA NeMo, recommended |
| **onnx-asr** | No | Fast | Good | Optimized for CPU, no GPU needed |
| **pywhispercpp** | Optional | Medium | High | Whisper models (tiny to large-v3) |
| **REST API** | No | Varies | High | ElevenLabs, custom endpoints |
| **Realtime WebSocket** | No | Fast | High | Streaming transcription |

### GPU Acceleration

- **NVIDIA**: CUDA acceleration (auto-detected by setup)
- **AMD/Intel**: Vulkan acceleration
- **CPU-only**: onnx-asr backend recommended

## Configuration

Config file: `~/.config/hyprwhspr/config.toml` (created by `hyprwhspr setup`)

Key settings:

- **Backend selection**: Parakeet, Whisper, REST API, WebSocket
- **Hotkey customization**: Custom key bindings, secondary shortcuts
- **Word overrides**: Correct common transcription errors
- **Audio ducking**: Reduce system volume during recording
- **Auto-submit**: Optionally press Enter after paste
- **Waybar integration**: Status bar indicator

Full configuration docs: [CONFIGURATION.md](https://github.com/goodroot/hyprwhspr/blob/main/docs/CONFIGURATION.md)

## Troubleshooting

| Issue | Solution |
|-------|---------|
| No audio input | Check `hyprwhspr test --mic-only`, verify mic in audio settings |
| Permission denied | Log out/in after setup for group permissions |
| ydotool not working | Ensure ydotool 1.0+ (`ydotool --version`), check systemd service |
| Text not pasting | Verify `wl-clipboard` installed, check Wayland session |
| High latency | Switch to onnx-asr or Parakeet backend |

```bash
# Check logs
journalctl --user -u hyprwhspr.service
journalctl --user -u ydotool.service

# Test end-to-end
hyprwhspr test --live
```

## Requirements

- Linux with systemd
- Wayland session (GNOME, KDE Plasma Wayland, Sway, Hyprland)
- `wl-clipboard`, `ydotool` 1.0+, `pipewire`
- Python 3.10+
- Optional: `gtk4` + `gtk4-layer-shell` (visualizer), Waybar (status bar)

## Related

- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD + STT + LLM + TTS)
- `tools/voice/transcription.md` - Audio/video transcription (file-based)
- `tools/voice/buzz.md` - Offline Whisper transcription (GUI/CLI)
- `tools/voice/voice-models.md` - Voice AI model selection
- `voice-helper.sh talk` - Voice bridge for talking to AI agents
