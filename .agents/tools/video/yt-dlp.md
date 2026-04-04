---
description: "yt-dlp - Download YouTube video, audio, playlists, channels, and transcripts"
mode: subagent
context7_id: /yt-dlp/yt-dlp
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# yt-dlp - YouTube Downloader

Feature-rich command-line audio/video downloader supporting YouTube and thousands of other sites. Downloads to `~/Downloads/` in organized, named folders.

Use when the user wants to download videos/audio, extract audio from local files, get transcripts, or archive channels/playlists.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `yt-dlp-helper.sh video <url>` | Download video (best quality, max 1080p) |
| `yt-dlp-helper.sh audio <url>` | Extract audio as MP3 |
| `yt-dlp-helper.sh playlist <url>` | Download full playlist |
| `yt-dlp-helper.sh channel <url>` | Download all channel videos |
| `yt-dlp-helper.sh transcript <url>` | Download subtitles/transcript only |
| `yt-dlp-helper.sh info <url>` | Show video info (no download) |
| `yt-dlp-helper.sh convert <path>` | Extract audio from local video file(s) |
| `yt-dlp-helper.sh install` | Install yt-dlp + ffmpeg |
| `yt-dlp-helper.sh update` | Update yt-dlp to latest |
| `yt-dlp-helper.sh config` | Generate default config file |
| `yt-dlp-helper.sh status` | Check installation status |

## Output Directory Structure

```text
~/Downloads/
  yt-dlp-video-{title}-{yyyy-mm-dd-hh-mm}/
  yt-dlp-audio-{title}-{yyyy-mm-dd-hh-mm}/
  yt-dlp-playlist-{playlist-name}-{yyyy-mm-dd-hh-mm}/
  yt-dlp-channel-{channel-name}-{yyyy-mm-dd-hh-mm}/
  yt-dlp-transcript-{title}-{yyyy-mm-dd-hh-mm}/
```

Override with `--output-dir <path>`.

## Default Settings

Configurable via `~/.config/yt-dlp/config`:

| Setting | Default | Override |
|---------|---------|----------|
| Max resolution | 1080p | `--format 4k`, `--format 720p` |
| Audio format | MP3 (best VBR) | `--format audio-m4a` |
| Metadata | Embedded (chapters, thumbnail) | `--no-metadata` |
| Info JSON | Written alongside | `--no-info-json` |
| SponsorBlock | Remove sponsors | `--no-sponsorblock` |
| Download archive | `~/.config/yt-dlp/archive.txt` | `--no-archive` |
| Rate limiting | 1-5s sleep between downloads | `--no-sleep` |
| Subtitles | Auto-generated English (SRT) | `--sub-langs all` |

## Common Workflows

```bash
# Single video
yt-dlp-helper.sh video "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Audio as MP3
yt-dlp-helper.sh audio "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Full playlist
yt-dlp-helper.sh playlist "https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"

# Channel archive
yt-dlp-helper.sh channel "https://www.youtube.com/@channelname"

# Transcript only
yt-dlp-helper.sh transcript "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Private/age-restricted (browser cookies)
yt-dlp-helper.sh video "https://www.youtube.com/watch?v=PRIVATE" --cookies

# 4K download
yt-dlp-helper.sh video "https://www.youtube.com/watch?v=dQw4w9WgXcQ" --format 4k

# Custom output directory
yt-dlp-helper.sh video "https://www.youtube.com/watch?v=dQw4w9WgXcQ" --output-dir ~/Videos/research
```

## Format Selection

| Shorthand | yt-dlp format string | Description |
|-----------|---------------------|-------------|
| `4k` | `bv*[height<=2160]+ba/b[height<=2160]` | Best up to 4K |
| `1080p` (default) | `bv*[height<=1080]+ba/b[height<=1080]` | Best up to 1080p |
| `720p` | `bv*[height<=720]+ba/b[height<=720]` | Best up to 720p |
| `480p` | `bv*[height<=480]+ba/b[height<=480]` | Best up to 480p |
| `audio-mp3` | `bestaudio/best` + extract MP3 | Audio only, MP3 |
| `audio-m4a` | `bestaudio/best` + extract M4A | Audio only, M4A |
| `audio-opus` | `bestaudio/best` + extract Opus | Audio only, Opus |

## Configuration File

`config` command generates `~/.config/yt-dlp/config`:

```text
--output ~/Downloads/%(title)s.%(ext)s
--format bestvideo[height<=1080]+bestaudio/best[height<=1080]
--embed-metadata
--embed-thumbnail
--embed-chapters
--embed-subs
--sub-langs en
--write-auto-subs
--convert-subs srt
--write-info-json
--download-archive ~/.config/yt-dlp/archive.txt
--sponsorblock-remove sponsor
--sleep-interval 1
--max-sleep-interval 5
--ignore-errors
--no-overwrites
--continue
```

## SponsorBlock Integration

```bash
--sponsorblock-remove sponsor   # Remove sponsor segments (default)
--sponsorblock-remove all       # Remove all non-content segments
--sponsorblock-mark all         # Mark segments in chapters instead
--no-sponsorblock               # Disable SponsorBlock
```

Categories: `sponsor`, `intro`, `outro`, `selfpromo`, `preview`, `filler`, `interaction`, `music_offtopic`, `poi_highlight`, `chapter`, `all`.

## Subtitle/Transcript Options

```bash
--write-auto-subs --sub-langs en --convert-subs srt   # Auto-generated English (default)
--write-subs --sub-langs all                           # All available languages
--write-subs --sub-langs "en,es,fr"                   # Specific languages
--embed-subs                                           # Embed into video file
```

## Local File Conversion

Extract audio from local video files using ffmpeg (no internet required):

```bash
yt-dlp-helper.sh convert ~/Videos/lecture.mp4              # Single file -> MP3
yt-dlp-helper.sh convert ~/Videos/ --format m4a            # Directory -> M4A
yt-dlp-helper.sh convert recording.mkv --format flac       # To FLAC (lossless)
yt-dlp-helper.sh convert ~/Videos/ --output-dir ~/Music/   # Custom output dir
```

Input: `mp4`, `mkv`, `webm`, `avi`, `mov`, `flv`, `wmv`, `m4v`, `ts`.

| Format | Codec | Use case |
|--------|-------|----------|
| `mp3` (default) | libmp3lame | Universal compatibility |
| `m4a` | AAC | Better quality, Apple ecosystem |
| `opus` | libopus | Best quality-to-size ratio |
| `wav` | PCM | Lossless, uncompressed |
| `flac` | FLAC | Lossless, compressed |

## Authentication

For private, age-restricted, or member-only content:

```bash
yt-dlp-helper.sh video <url> --cookies
# Uses: --cookies-from-browser chrome
# Alternatives: firefox, safari, edge, brave, opera, vivaldi
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Video unavailable" | Try `--cookies` for age-restricted content |
| Slow downloads | Check `--limit-rate` or ISP throttling |
| Missing audio | Ensure `ffmpeg` is installed (`yt-dlp-helper.sh install`) |
| Format not available | Use `yt-dlp-helper.sh info <url>` to see available formats |
| Already downloaded | Check `~/.config/yt-dlp/archive.txt` or use `--no-archive` |

## Dependencies

Installed automatically by `yt-dlp-helper.sh install`:

| Dependency | Purpose | Manual install |
|------------|---------|----------------|
| **yt-dlp** | Core downloader (YouTube + 1000s of sites) | `brew install yt-dlp` or `pip install yt-dlp` |
| **ffmpeg** | Merge video+audio, extract audio, convert formats | `brew install ffmpeg` |

OS detection: macOS (Homebrew), Debian/Ubuntu (apt+pip), Fedora (dnf+pip), Arch (pacman). Falls back to pip+manual ffmpeg. Every download command checks for dependencies and prompts to run `install` if missing.

## Context7 Integration

```text
resolve-library-id("yt-dlp")
# Returns: /yt-dlp/yt-dlp

query-docs("/yt-dlp/yt-dlp", "output template format selection")
query-docs("/yt-dlp/yt-dlp", "subtitle download and conversion")
query-docs("/yt-dlp/yt-dlp", "SponsorBlock integration")
```

## Related

- [yt-dlp GitHub](https://github.com/yt-dlp/yt-dlp)
- [yt-dlp Wiki](https://github.com/yt-dlp/yt-dlp/wiki)
- `tools/video/remotion.md` - Programmatic video editing
- `tools/video/video-prompt-design.md` - Video prompt design
