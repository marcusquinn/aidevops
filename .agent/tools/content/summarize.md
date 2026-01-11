---
description: URL/YouTube/podcast summarization using steipete/summarize CLI
mode: subagent
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

# Summarize CLI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Summarize URLs, YouTube videos, podcasts, and files using AI
- **Install**: `npm i -g @steipete/summarize` or `brew install steipete/tap/summarize`
- **Repo**: https://github.com/steipete/summarize (726+ stars)
- **Website**: https://summarize.sh

**Quick Commands**:

```bash
# Summarize any URL
summarize "https://example.com"

# YouTube video
summarize "https://youtu.be/dQw4w9WgXcQ" --youtube auto

# Podcast RSS feed
summarize "https://feeds.npr.org/500005/podcast.xml"

# Local file (PDF, images, audio/video)
summarize "/path/to/file.pdf" --model google/gemini-3-flash-preview

# Extract content only (no summary)
summarize "https://example.com" --extract --format md
```

**Key Features**:

- URLs, files, and media: web pages, PDFs, images, audio/video, YouTube, podcasts, RSS
- Real extraction pipeline: fetch -> clean -> Markdown (readability + markitdown)
- Transcript-first media flow: published transcripts when available, Whisper fallback
- Streaming TTY output with Markdown rendering
- Local, paid, and free models: OpenAI-compatible local endpoints, paid providers, OpenRouter free preset

**Env Vars**: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`

<!-- AI-CONTEXT-END -->

## Installation

### npm (recommended)

```bash
# Global install
npm i -g @steipete/summarize

# One-shot (no install)
npx -y @steipete/summarize "https://example.com"
```

### Homebrew (macOS Apple Silicon)

```bash
brew install steipete/tap/summarize
```

### Requirements

- Node.js 22+
- Optional: `yt-dlp` for YouTube audio extraction
- Optional: `whisper.cpp` for local transcription
- Optional: `uvx markitdown` for enhanced preprocessing

## Usage

### Basic Summarization

```bash
# Web page
summarize "https://example.com"

# With specific model
summarize "https://example.com" --model openai/gpt-5-mini

# Auto model selection (default)
summarize "https://example.com" --model auto
```

### YouTube Videos

```bash
# Auto-detect transcript method
summarize "https://youtu.be/dQw4w9WgXcQ" --youtube auto

# Supports youtube.com and youtu.be URLs
summarize "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

### Podcasts

```bash
# RSS feed (transcribes latest episode)
summarize "https://feeds.npr.org/500005/podcast.xml"

# Apple Podcasts episode
summarize "https://podcasts.apple.com/us/podcast/2424-jelly-roll/id360084272?i=1000740717432"

# Spotify episode (best-effort)
summarize "https://open.spotify.com/episode/5auotqWAXhhKyb9ymCuBJY"
```

### Local Files

```bash
# PDF (Google models work best)
summarize "/path/to/document.pdf" --model google/gemini-3-flash-preview

# Images
summarize "/path/to/image.png"

# Audio/Video
summarize "/path/to/video.mp4" --video-mode transcript
```

### Output Control

```bash
# Length presets: short, medium, long, xl, xxl
summarize "https://example.com" --length long

# Character target
summarize "https://example.com" --length 20k

# Hard token cap
summarize "https://example.com" --max-output-tokens 2000

# Output language
summarize "https://example.com" --language en
summarize "https://example.com" --lang auto  # match source
```

### Content Extraction

```bash
# Extract content without summarizing
summarize "https://example.com" --extract

# Extract as Markdown
summarize "https://example.com" --extract --format md

# Extract as plain text
summarize "https://example.com" --extract --format text
```

### Output Formats

```bash
# JSON output with diagnostics
summarize "https://example.com" --json

# Plain output (no ANSI/colors)
summarize "https://example.com" --plain

# Disable streaming
summarize "https://example.com" --stream off
```

## Model Configuration

### Supported Providers

| Provider | Model ID Format | API Key |
|----------|-----------------|---------|
| OpenAI | `openai/gpt-5-mini` | `OPENAI_API_KEY` |
| Anthropic | `anthropic/claude-sonnet-4-5` | `ANTHROPIC_API_KEY` |
| Google | `google/gemini-3-flash-preview` | `GEMINI_API_KEY` |
| xAI | `xai/grok-4-fast-non-reasoning` | `XAI_API_KEY` |
| Z.AI | `zai/glm-4.7` | `Z_AI_API_KEY` |
| OpenRouter | `openrouter/openai/gpt-5-mini` | `OPENROUTER_API_KEY` |

### Free Models via OpenRouter

```bash
# Setup free model preset
OPENROUTER_API_KEY=sk-or-... summarize refresh-free --set-default

# Use free models
summarize "https://example.com" --model free
```

### Configuration File

Location: `~/.summarize/config.json`

```json
{
  "model": { "id": "openai/gpt-5-mini" }
}
```

Or shorthand:

```json
{
  "model": "openai/gpt-5-mini"
}
```

## Chrome Extension

Summarize includes a Chrome Side Panel extension for one-click summarization.

### Setup

1. Install CLI: `npm i -g @steipete/summarize`
2. Build extension: `pnpm -C apps/chrome-extension build`
3. Load in Chrome: `chrome://extensions` -> Developer mode -> Load unpacked
4. Pick: `apps/chrome-extension/.output/chrome-mv3`
5. Open Side Panel -> copy install command
6. Run: `summarize daemon install --token <TOKEN>`

### Daemon Commands

```bash
# Check daemon status
summarize daemon status

# Restart daemon
summarize daemon restart
```

## Advanced Features

### Firecrawl Fallback

For blocked or thin content, Firecrawl can be used as fallback:

```bash
# Auto fallback (default)
summarize "https://example.com" --firecrawl auto

# Force Firecrawl
summarize "https://example.com" --firecrawl always

# Disable Firecrawl
summarize "https://example.com" --firecrawl off
```

Requires `FIRECRAWL_API_KEY` environment variable.

### Whisper Transcription

For audio/video without transcripts:

```bash
# Force transcription mode
summarize "/path/to/video.mp4" --video-mode transcript

# Environment variables
export SUMMARIZE_WHISPER_CPP_MODEL_PATH=/path/to/model.bin
export SUMMARIZE_WHISPER_CPP_BINARY=whisper-cli
export SUMMARIZE_DISABLE_LOCAL_WHISPER_CPP=1  # force remote
```

### Markdown Conversion

```bash
# Readability mode (default)
summarize "https://example.com" --markdown-mode readability

# LLM conversion
summarize "https://example.com" --markdown-mode llm

# Auto (LLM when configured)
summarize "https://example.com" --markdown-mode auto

# Disable
summarize "https://example.com" --markdown-mode off
```

## Common Flags

| Flag | Description |
|------|-------------|
| `--model <provider/model>` | Model to use (default: `auto`) |
| `--timeout <duration>` | Request timeout (`30s`, `2m`, `5000ms`) |
| `--retries <count>` | LLM retry attempts (default: 1) |
| `--length <preset\|chars>` | Output length control |
| `--language, --lang` | Output language (`auto` = match source) |
| `--max-output-tokens` | Hard cap for LLM output tokens |
| `--stream auto\|on\|off` | Stream LLM output |
| `--plain` | No ANSI/OSC Markdown rendering |
| `--no-color` | Disable ANSI colors |
| `--format md\|text` | Content format |
| `--extract` | Print extracted content and exit |
| `--json` | Machine-readable output |
| `--verbose` | Debug/diagnostics on stderr |
| `--metrics off\|on\|detailed` | Metrics output |

## Integration with aidevops

### Use Cases

1. **Research**: Summarize articles, papers, documentation
2. **Content Curation**: Extract key points from multiple sources
3. **Podcast Notes**: Generate show notes from episodes
4. **Video Summaries**: Create text summaries of YouTube content
5. **Document Processing**: Summarize PDFs and reports

### Example Workflow

```bash
# Research a topic
summarize "https://docs.example.com/api" --length long --json > api-summary.json

# Summarize multiple sources
for url in "${urls[@]}"; do
  summarize "$url" --length medium >> research-notes.md
done

# Extract and process
summarize "https://example.com" --extract --format md | process-content.sh
```

## Troubleshooting

### Common Issues

1. **Model not responding**: Check API key is set correctly
2. **YouTube transcript unavailable**: Install `yt-dlp` for audio extraction
3. **PDF extraction failing**: Use Google models for best PDF support
4. **Rate limiting**: Add `--timeout` and `--retries` flags

### Debug Mode

```bash
summarize "https://example.com" --verbose
```

## Resources

- **GitHub**: https://github.com/steipete/summarize
- **Website**: https://summarize.sh
- **npm**: https://www.npmjs.com/package/@steipete/summarize
- **Docs**: https://github.com/steipete/summarize/tree/main/docs
