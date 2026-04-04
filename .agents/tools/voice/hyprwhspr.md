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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# hyprwhspr - Linux Speech-to-Text

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: System-wide speech-to-text dictation on Linux (Wayland)
- **Source**: [goodroot/hyprwhspr](https://github.com/goodroot/hyprwhspr) (MIT, 790+ stars)
- **Platform**: Linux only (Arch, Debian, Ubuntu, Fedora, openSUSE) with Wayland (Hyprland, GNOME, KDE, Sway)
- **Backends**: Parakeet TDT V3 (recommended), onnx-asr (CPU), pywhispercpp, ElevenLabs REST, Realtime WebSocket
- **Default hotkey**: `Super+Alt+D` (toggle dictation)
- **Config**: `~/.config/hyprwhspr/config.toml` — [CONFIGURATION.md](https://github.com/goodroot/hyprwhspr/blob/main/docs/CONFIGURATION.md)

**When to use**: Setting up voice dictation on Linux desktops, especially Arch/Omarchy with Hyprland. For macOS, use built-in Dictation or `voice-helper.sh talk` instead.

<!-- AI-CONTEXT-END -->

## Installation

### Arch Linux (AUR)

```bash
yay -S hyprwhspr        # stable
yay -S hyprwhspr-git    # bleeding edge
hyprwhspr setup         # interactive setup (backend, models, services)
```

### Debian / Ubuntu / Fedora / openSUSE

```bash
curl -fsSL https://raw.githubusercontent.com/goodroot/hyprwhspr/main/scripts/install-deps.sh | bash
git clone https://github.com/goodroot/hyprwhspr.git ~/hyprwhspr
cd ~/hyprwhspr && ./bin/hyprwhspr setup
```

Log out and back in for group permissions, then verify:

```bash
hyprwhspr status && hyprwhspr validate
```

## Usage

Press `Super+Alt+D` to start (beep), speak, press again to stop (boop) — text auto-pastes into the active buffer.

**Recording modes**: Toggle (default) · Push-to-talk (hold key) · Long-form (pause/resume/submit)

## CLI Commands

| Command | Purpose |
|---------|---------|
| `hyprwhspr setup` | Interactive initial setup |
| `hyprwhspr setup auto` | Automated setup (`--backend`, `--model`, `--no-waybar`) |
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

| Backend | GPU | Speed | Quality | Notes |
|---------|-----|-------|---------|-------|
| **Parakeet TDT V3** | Optional (CUDA/Vulkan) | Fast | High | NVIDIA NeMo, recommended |
| **onnx-asr** | No | Fast | Good | CPU-optimised, best for no-GPU |
| **pywhispercpp** | Optional | Medium | High | Whisper tiny–large-v3 |
| **REST API** | No | Varies | High | ElevenLabs, custom endpoints |
| **Realtime WebSocket** | No | Fast | High | Streaming transcription |

GPU: NVIDIA → CUDA (auto-detected), AMD/Intel → Vulkan, CPU-only → use onnx-asr.

## Troubleshooting

| Issue | Solution |
|-------|---------|
| No audio input | `hyprwhspr test --mic-only`, verify mic in audio settings |
| Permission denied | Log out/in after setup for group permissions |
| ydotool not working | Ensure ydotool 1.0+ (`ydotool --version`), check systemd service |
| Text not pasting | Verify `wl-clipboard` installed, check Wayland session |
| High latency | Switch to onnx-asr or Parakeet backend |

```bash
journalctl --user -u hyprwhspr.service   # check logs
journalctl --user -u ydotool.service
hyprwhspr test --live                    # end-to-end test
```

## Requirements

Linux + systemd, Wayland (GNOME/KDE/Sway/Hyprland), `wl-clipboard` + `ydotool` 1.0+ + `pipewire`, Python 3.10+. Optional: `gtk4` + `gtk4-layer-shell` (visualizer), Waybar.

## Related

- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD + STT + LLM + TTS)
- `tools/voice/transcription.md` - Audio/video transcription (file-based)
- `tools/voice/buzz.md` - Offline Whisper transcription (GUI/CLI)
- `tools/voice/voice-models.md` - Voice AI model selection
- `voice-helper.sh talk` - Voice bridge for talking to AI agents
