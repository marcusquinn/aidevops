---
description: Download YouTube video, audio, playlist, channel, or transcript using yt-dlp
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Arguments: $ARGUMENTS

## Commands

```text
/yt-dlp <url>                          → Auto-detect (video/playlist/channel)
/yt-dlp video <url> [options]          → Download video
/yt-dlp audio <url> [options]          → Extract audio (mp3 by default)
/yt-dlp playlist <url> [options]       → Download playlist
/yt-dlp channel <url> [options]        → Download channel
/yt-dlp transcript <url> [options]     → Download subtitles only
/yt-dlp info <url>                     → Show video info
/yt-dlp convert <path> [options]       → Extract audio from local file(s)
/yt-dlp install                        → Install yt-dlp + ffmpeg
/yt-dlp status                         → Check installation
/yt-dlp config                         → Write default config to ~/.config/yt-dlp/config
```

URL-only auto-detect: `playlist?list=` → `playlist`; `/@`, `/c/`, `/channel/` → `channel`; otherwise → `video`.

## Execution

Check deps, then run:

```bash
~/.aidevops/agents/scripts/yt-dlp-helper.sh status
~/.aidevops/agents/scripts/yt-dlp-helper.sh <command> <url> [options]
```

If deps missing, offer: `yt-dlp-helper.sh install`

## Options

| Option | Description |
|--------|-------------|
| `--output-dir <path>` | Custom output directory |
| `--format <fmt>` | Video/audio: `4k`, `1080p`, `720p`, `480p`, `mp3`, `m4a`, `opus`; convert only: `wav`, `flac` |
| `--cookies` | Use Chrome cookies (private/age-restricted content) |
| `--no-archive` | Allow re-downloading already-fetched videos |
| `--no-sponsorblock` | Keep sponsor segments |
| `--no-metadata` | Skip metadata/thumbnail embedding |
| `--sub-langs <langs>` | Subtitle languages (default: `en`, use `all` for all) |

## Examples

```text
/yt-dlp https://www.youtube.com/watch?v=dQw4w9WgXcQ
/yt-dlp audio https://www.youtube.com/playlist?list=PLxxx --format m4a
/yt-dlp transcript https://www.youtube.com/watch?v=dQw4w9WgXcQ --sub-langs en,es
/yt-dlp convert ~/Videos/lecture.mp4 --format flac
/yt-dlp https://www.youtube.com/watch?v=PRIVATE --cookies
```

## Related

- `tools/video/yt-dlp.md` - Full agent documentation
- `scripts/yt-dlp-helper.sh` - Helper script reference
