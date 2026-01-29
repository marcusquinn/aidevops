---
description: Download YouTube video, audio, playlist, channel, or transcript using yt-dlp
agent: Build+
mode: subagent
---

Download media from YouTube (or other supported sites) using yt-dlp.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Parse Arguments

Parse `$ARGUMENTS` to determine the mode and URL:

```text
/yt-dlp <url>                          → Auto-detect (video/playlist/channel)
/yt-dlp video <url> [options]          → Download video
/yt-dlp audio <url> [options]          → Extract audio (MP3)
/yt-dlp playlist <url> [options]       → Download playlist
/yt-dlp channel <url> [options]        → Download channel
/yt-dlp transcript <url> [options]     → Download subtitles only
/yt-dlp info <url>                     → Show video info
/yt-dlp convert <path> [options]       → Extract audio from local file(s)
/yt-dlp install                        → Install yt-dlp + ffmpeg
/yt-dlp status                         → Check installation
/yt-dlp config                         → Generate default config
```

If only a URL is provided (no subcommand), auto-detect:
- Playlist URL (`playlist?list=`) → `playlist`
- Channel URL (`/@`, `/c/`, `/channel/`) → `channel`
- Otherwise → `video`

### Step 2: Check Dependencies

```bash
~/.aidevops/agents/scripts/yt-dlp-helper.sh status
```

If yt-dlp or ffmpeg is missing, offer to install:

```bash
~/.aidevops/agents/scripts/yt-dlp-helper.sh install
```

### Step 3: Execute Download

Run the appropriate helper command:

```bash
~/.aidevops/agents/scripts/yt-dlp-helper.sh <command> <url> [options]
```

### Step 4: Report Results

Show the output directory and downloaded files:

```text
Downloaded to: ~/Downloads/yt-dlp-{type}-{name}-{timestamp}/
Files:
  - Video Title.mp4 (1.2GB)
  - Video Title.en.srt
  - Video Title.info.json
```

## Options

Pass through to the helper script:

| Option | Description |
|--------|-------------|
| `--output-dir <path>` | Custom output directory |
| `--format <fmt>` | Format: `4k`, `1080p`, `720p`, `480p`, `mp3`, `m4a`, `opus`, `wav`, `flac` |
| `--cookies` | Use Chrome cookies (private/age-restricted content) |
| `--no-archive` | Allow re-downloading already-fetched videos |
| `--no-sponsorblock` | Keep sponsor segments |
| `--no-metadata` | Skip metadata/thumbnail embedding |
| `--sub-langs <langs>` | Subtitle languages (default: `en`, use `all` for all) |

## Examples

**Download a video (auto-detect):**

```text
/yt-dlp https://www.youtube.com/watch?v=dQw4w9WgXcQ
```

**Extract audio as MP3:**

```text
/yt-dlp audio https://www.youtube.com/watch?v=dQw4w9WgXcQ
```

**Download in 4K:**

```text
/yt-dlp video https://www.youtube.com/watch?v=dQw4w9WgXcQ --format 4k
```

**Download playlist as audio:**

```text
/yt-dlp audio https://www.youtube.com/playlist?list=PLxxx --format m4a
```

**Get transcript only:**

```text
/yt-dlp transcript https://www.youtube.com/watch?v=dQw4w9WgXcQ --sub-langs en,es
```

**Convert local video to audio:**

```text
/yt-dlp convert ~/Videos/lecture.mp4 --format flac
```

**Download private video with cookies:**

```text
/yt-dlp https://www.youtube.com/watch?v=PRIVATE --cookies
```

**Check what's installed:**

```text
/yt-dlp status
```

## Related

- `tools/video/yt-dlp.md` - Full agent documentation
- `scripts/yt-dlp-helper.sh` - Helper script reference
