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

- **Install**: `npm i -g @steipete/summarize` or `brew install steipete/tap/summarize`
- **Repo**: https://github.com/steipete/summarize
- **Docs**: https://github.com/steipete/summarize/tree/main/docs
- **Env Vars**: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`

```bash
summarize "https://example.com"                                          # web page
summarize "https://youtu.be/dQw4w9WgXcQ" --youtube auto                 # YouTube
summarize "https://feeds.npr.org/500005/podcast.xml"                     # podcast RSS
summarize "/path/to/file.pdf" --model google/gemini-3-flash-preview      # local file
summarize "https://example.com" --extract --format md                    # extract only
npx -y @steipete/summarize "https://example.com"                         # one-shot
```

**Features**: web pages, PDFs, images, audio/video, YouTube, podcasts, RSS. Extraction pipeline: fetch → clean → Markdown (readability + markitdown). Transcript-first for media; Whisper fallback. Streaming TTY output. Local, paid, and free models via OpenRouter.

<!-- AI-CONTEXT-END -->

## Requirements

- Node.js 22+
- Optional: `yt-dlp` (YouTube audio), `whisper.cpp` (local transcription), `uvx markitdown` (enhanced preprocessing)

## Usage

```bash
# Basic
summarize "https://example.com" --model openai/gpt-5-mini

# YouTube (youtube.com and youtu.be both work)
summarize "https://youtu.be/dQw4w9WgXcQ" --youtube auto

# Podcasts
summarize "https://feeds.npr.org/500005/podcast.xml"                     # RSS (latest episode)
summarize "https://podcasts.apple.com/us/podcast/2424-jelly-roll/id360084272?i=1000740717432"
summarize "https://open.spotify.com/episode/5auotqWAXhhKyb9ymCuBJY"     # best-effort

# Local files
summarize "/path/to/document.pdf" --model google/gemini-3-flash-preview  # PDF
summarize "/path/to/image.png"
summarize "/path/to/video.mp4" --video-mode transcript

# Output control
summarize "https://example.com" --length long          # presets: short, medium, long, xl, xxl
summarize "https://example.com" --length 20k           # character target
summarize "https://example.com" --max-output-tokens 2000
summarize "https://example.com" --language en
summarize "https://example.com" --lang auto            # match source language

# Extraction (no summary)
summarize "https://example.com" --extract --format md
summarize "https://example.com" --extract --format text

# Output format
summarize "https://example.com" --json                 # machine-readable with diagnostics
summarize "https://example.com" --plain                # no ANSI/colors
summarize "https://example.com" --stream off
```

## Model Configuration

| Provider | Model ID Format | API Key |
|----------|-----------------|---------|
| OpenAI | `openai/gpt-5-mini` | `OPENAI_API_KEY` |
| Anthropic | `anthropic/claude-sonnet-4-6` | `ANTHROPIC_API_KEY` |
| Google | `google/gemini-3-flash-preview` | `GEMINI_API_KEY` |
| xAI | `xai/grok-4-fast-non-reasoning` | `XAI_API_KEY` |
| Z.AI (Zhipu) | `zai/glm-4.7` | `Z_AI_API_KEY` |
| OpenRouter | `openrouter/openai/gpt-5-mini` | `OPENROUTER_API_KEY` |

**Free models via OpenRouter:**

```bash
OPENROUTER_API_KEY=sk-or-... summarize refresh-free --set-default
summarize "https://example.com" --model free
```

**Config file** (`~/.summarize/config.json`):

```json
{ "model": "openai/gpt-5-mini" }
```

## Chrome Extension

Side Panel extension for one-click summarization.

1. Install CLI: `npm i -g @steipete/summarize`
2. Build: `pnpm -C apps/chrome-extension build`
3. Load in Chrome: `chrome://extensions` → Developer mode → Load unpacked → `apps/chrome-extension/.output/chrome-mv3`
4. Open Side Panel → copy install command → run: `summarize daemon install --token <TOKEN>`

```bash
summarize daemon status
summarize daemon restart
```

## Advanced Features

**Firecrawl** (blocked/thin content fallback, requires `FIRECRAWL_API_KEY`):

```bash
summarize "https://example.com" --firecrawl auto     # default
summarize "https://example.com" --firecrawl always
summarize "https://example.com" --firecrawl off
```

**Whisper** (audio/video without transcripts):

```bash
export SUMMARIZE_WHISPER_CPP_MODEL_PATH=/path/to/model.bin
export SUMMARIZE_WHISPER_CPP_BINARY=whisper-cli
export SUMMARIZE_DISABLE_LOCAL_WHISPER_CPP=1         # force remote
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
| `--markdown-mode readability\|llm\|auto\|off` | Markdown conversion mode |
| `--video-mode transcript` | Force transcription for video |
| `--youtube auto` | YouTube transcript method |
| `--firecrawl auto\|always\|off` | Firecrawl fallback mode |

## Example Workflow

```bash
# Research a topic
summarize "https://docs.example.com/api" --length long --json > api-summary.json

# Summarize multiple sources
urls=("https://example.com/page1" "https://example.com/page2")
for url in "${urls[@]}"; do
  summarize "$url" --length medium >> research-notes.md
done

# Extract and process
summarize "https://example.com" --extract --format md | process-content.sh
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Model not responding | Check API key is set |
| YouTube transcript unavailable | Install `yt-dlp` |
| PDF extraction failing | Use `--model google/gemini-3-flash-preview` |
| Rate limiting | Add `--timeout` and `--retries` |

```bash
summarize "https://example.com" --verbose   # debug mode
```
