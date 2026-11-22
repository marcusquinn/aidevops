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
- **Source**: [goodroot/hyprwhspr](https://github.com/goodroot/hyprwhspr) (MIT)
- **Platform**: Linux only (Arch, Debian, Ubuntu, Fedora, openSUSE) with Wayland (Hyprland, GNOME, KDE, Sway)
- **Backends**: pick by hardware — NVIDIA → Cohere Transcribe; CPU → Parakeet or faster-whisper; AMD/Intel → Parakeet.cpp or whisper.cpp (Vulkan). See [Transcription Backends](#transcription-backends)
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

Upstream's one-line installer (see the [README install section](https://github.com/goodroot/hyprwhspr#install)) installs dependencies, clones to `~/.local/share/hyprwhspr/src`, and runs setup. Manual install:

```bash
git clone https://github.com/goodroot/hyprwhspr.git
cd hyprwhspr
./scripts/install-deps.sh   # dependencies for your distro
./bin/hyprwhspr setup       # interactive setup
```

Nix/NixOS (beta, x86_64, whisper.cpp CPU): upstream flake — [docs/integrations/NIX.md](https://github.com/goodroot/hyprwhspr/blob/main/docs/integrations/NIX.md).

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
| `hyprwhspr model unload` / `reload` | Free the model's VRAM/RAM without stopping the service, then load it again |
| `hyprwhspr waybar` | Manage Waybar integration |
| `hyprwhspr mic-osd` | Manage microphone visualizer overlay |
| `hyprwhspr systemd` | Manage systemd services |
| `hyprwhspr keyboard` | Keyboard device management |
| `hyprwhspr backend` | Backend management (repair/reset) |
| `hyprwhspr uninstall` | Complete removal |

## Transcription Backends

Upstream is the source of truth: [docs/backends/OVERVIEW.md](https://github.com/goodroot/hyprwhspr/blob/main/docs/backends/OVERVIEW.md). Summary by hardware:

| Hardware | Pick | Memory | Notes |
|----------|------|-------:|-------|
| NVIDIA GPU, ≥ ~5 GB VRAM free | **Cohere Transcribe** (PyTorch) | 4 GB | Top accuracy, 14 languages |
| NVIDIA GPU, small/shared VRAM | **Parakeet v3** (ONNX) | 1 GB | 25 European languages |
| CPU only | **Parakeet v3** or **faster-whisper** | 1–1.6 GB | Whisper covers 99 languages |
| AMD / Intel GPU | **Parakeet.cpp** or **whisper.cpp** (Vulkan) | 0.9–1.6 GB | whisper.cpp for 99 languages |
| ARM64 | **Parakeet v3** | 1 GB | Runs on CPU |
| Chinese / Japanese / Korean | **Qwen3-ASR** (llama.cpp, experimental) | ~2.4 GB | 30 languages |
| No local setup | **REST API** / **Realtime WebSocket** | none | Cloud or self-hosted |

Orukeet (Parakeet variant) is also available, experimental. `hyprwhspr setup auto` picks Whisper for your hardware (faster-whisper on NVIDIA/CPU, whisper.cpp on AMD/Intel). On a small GPU shared with the desktop, `hyprwhspr model unload` frees VRAM; see upstream [MEMORY.md](https://github.com/goodroot/hyprwhspr/blob/main/docs/backends/MEMORY.md).

## Troubleshooting

| Issue | Solution |
|-------|---------|
| No audio input | `hyprwhspr test --mic-only`, verify mic in audio settings |
| Permission denied | Log out/in after setup for group permissions |
| ydotool not working | Ensure ydotool 1.0+ (`ydotool --version`), check systemd service |
| Text not pasting | Verify `wl-clipboard` installed, check Wayland session |
| High latency | Switch to Parakeet (CPU/NVIDIA) or Parakeet.cpp (AMD/Intel) |
| GPU memory pressure | `hyprwhspr model unload`, later `hyprwhspr model reload` |

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
