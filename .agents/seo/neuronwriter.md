---
description: NeuronWriter content optimization via REST API (curl-based, no MCP needed)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
---

# NeuronWriter - Content Optimization API

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: SEO content optimization, NLP term recommendations, content scoring, competitor analysis
- **API base**: `https://app.neuronwriter.com/neuron-api/0.5/writer`
- **Auth**: `X-API-KEY` header — key stored in `~/.config/aidevops/credentials.sh` as `NEURONWRITER_API_KEY`
- **Plan**: Gold or higher required
- **Docs**: https://neuronwriter.com/faq/
- **No MCP required** — uses curl directly

**API requests consume monthly limits** (same cost as using the NeuronWriter UI).

<!-- AI-CONTEXT-END -->

## Common Curl Pattern

All endpoints use POST with the same headers. Define once per script:

```bash
source ~/.config/aidevops/credentials.sh
NW_API="https://app.neuronwriter.com/neuron-api/0.5/writer"
NW_HEADERS=(-H "X-API-KEY: $NEURONWRITER_API_KEY" -H "Accept: application/json" -H "Content-Type: application/json")
```

Do not use `https://app.neuronwriter.com/api/v1/` — that is a different API.

Usage: `curl -s -X POST "$NW_API/<endpoint>" "${NW_HEADERS[@]}" -d '<json>'`

## API Endpoints

### `/list-projects`

Returns array of `{project, name, language, engine}`.

```bash
curl -s -X POST "$NW_API/list-projects" "${NW_HEADERS[@]}"
```

### `/new-query`

Creates a content writer query for a keyword. Takes ~60s to process.

```bash
curl -s -X POST "$NW_API/new-query" "${NW_HEADERS[@]}" \
  -d '{"project": "PROJECT_ID", "keyword": "trail running shoes", "engine": "google.co.uk", "language": "English"}'
```

| Param | Description |
|-------|-------------|
| `project` | Project ID from `/list-projects` or project URL |
| `keyword` | Target keyword to analyse |
| `engine` | Search engine (e.g. `google.com`, `google.co.uk`) |
| `language` | Content language (e.g. `English`) |

Returns `{query, query_url, share_url, readonly_url}`.

### `/get-query`

Retrieves SEO recommendations after processing (~60s after `/new-query`).

```bash
curl -s -X POST "$NW_API/get-query" "${NW_HEADERS[@]}" \
  -d '{"query": "QUERY_ID"}'
```

Response (when `status == "ready"`):

| Key | Description |
|-----|-------------|
| `status` | `not found`, `waiting`, `in progress`, `ready` |
| `metrics` | Word count target, readability target |
| `terms_txt` | NLP term suggestions as text (title, desc, h1, h2, content_basic, content_extended, entities) |
| `terms` | Detailed term data with usage percentages and suggested ranges |
| `ideas` | Suggested questions, People Also Ask, content questions |
| `competitors` | SERP competitors with URLs, titles, content scores |

### `/list-queries`

Filter queries within a project.

```bash
curl -s -X POST "$NW_API/list-queries" "${NW_HEADERS[@]}" \
  -d '{"project": "PROJECT_ID", "status": "ready", "source": "neuron-api"}'
```

| Param | Description |
|-------|-------------|
| `project` | Project ID |
| `status` | `waiting`, `in progress`, `ready` |
| `source` | `neuron` (UI) or `neuron-api` |
| `tags` | Single tag string or array of tags |
| `keyword` | Filter by keyword |
| `language` | Filter by language |
| `engine` | Filter by search engine |

### `/get-content`

Retrieve the last saved content revision for a query.

```bash
curl -s -X POST "$NW_API/get-content" "${NW_HEADERS[@]}" \
  -d '{"query": "QUERY_ID", "revision_type": "all"}'
```

| Param | Description |
|-------|-------------|
| `query` | Query ID |
| `revision_type` | `manual` (default) or `all` (includes autosave) |

Returns `{content, title, description, created, type}` — `content` is HTML, `type` is `manual` or `autosave`.

### `/import-content`

Push HTML content into the NeuronWriter editor. Creates a new content revision.

```bash
curl -s -X POST "$NW_API/import-content" "${NW_HEADERS[@]}" \
  -d '{"query": "QUERY_ID", "html": "<h1>Title</h1><p>Content...</p>", "title": "Title", "description": "Meta description."}'
```

| Param | Description |
|-------|-------------|
| `query` | Query ID |
| `html` | HTML content to import |
| `url` | Alternative: URL to auto-import content from |
| `title` | Optional: overrides title found in HTML/URL |
| `description` | Optional: overrides meta description found in HTML/URL |
| `id` | Optional: HTML element ID to extract content from (with `url`) |
| `class` | Optional: HTML element class to extract content from (with `url`) |

Returns `{"status": "ok", "content_score": 25}`.

### `/evaluate-content`

Same parameters as `/import-content`, but does **not** save a revision. Use to score content without modifying the editor.

```bash
curl -s -X POST "$NW_API/evaluate-content" "${NW_HEADERS[@]}" \
  -d '{"query": "QUERY_ID", "html": "<h1>Title</h1><p>Content...</p>"}'
```

## Workflows

### Create Query and Poll for Results

```bash
source ~/.config/aidevops/credentials.sh
NW_API="https://app.neuronwriter.com/neuron-api/0.5/writer"
NW_HEADERS=(-H "X-API-KEY: $NEURONWRITER_API_KEY" -H "Accept: application/json" -H "Content-Type: application/json")

# 1. Create query
RESULT=$(curl -s -X POST "$NW_API/new-query" "${NW_HEADERS[@]}" \
  -d '{"project": "YOUR_PROJECT_ID", "keyword": "your keyword", "engine": "google.com", "language": "English"}')
QUERY_ID=$(echo "$RESULT" | jq -r '.query')

if [[ -z "$QUERY_ID" || "$QUERY_ID" == "null" ]]; then
  echo "Error: Failed to create query. Response: $RESULT" >&2
  exit 1
fi

# 2. Poll until ready (every 15s, max 5 min)
for i in $(seq 1 20); do
  PAYLOAD=$(jq -n --arg qid "$QUERY_ID" '{query: $qid}')
  STATUS=$(curl -s -X POST "$NW_API/get-query" "${NW_HEADERS[@]}" \
    -d "$PAYLOAD" | jq -r '.status')
  [ "$STATUS" = "ready" ] && break
  sleep 15
done

if [ "$STATUS" != "ready" ]; then
  echo "Error: Query not ready after 5 min. Status: $STATUS" >&2
  exit 1
fi

# 3. Get recommendations
PAYLOAD=$(jq -n --arg qid "$QUERY_ID" '{query: $qid}')
curl -s -X POST "$NW_API/get-query" "${NW_HEADERS[@]}" \
  -d "$PAYLOAD" | jq '.terms_txt.content_basic'
```

### Score Existing Content

```bash
source ~/.config/aidevops/credentials.sh
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/evaluate-content" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"query": "EXISTING_QUERY_ID", "url": "https://example.com/your-article"}' | jq '.content_score'
```

### Bulk Keyword Analysis

```bash
source ~/.config/aidevops/credentials.sh
NW_API="https://app.neuronwriter.com/neuron-api/0.5/writer"
NW_HEADERS=(-H "X-API-KEY: $NEURONWRITER_API_KEY" -H "Accept: application/json" -H "Content-Type: application/json")

KEYWORDS=("trail running shoes" "best running gear" "marathon training tips")
PROJECT="YOUR_PROJECT_ID"

for kw in "${KEYWORDS[@]}"; do
  echo "Creating query for: $kw"
  PAYLOAD=$(jq -n --arg project "$PROJECT" --arg keyword "$kw" \
    --arg engine "google.com" --arg lang "English" \
    '{project: $project, keyword: $keyword, engine: $engine, language: $lang}')
  curl -s -X POST "$NW_API/new-query" "${NW_HEADERS[@]}" \
    -d "$PAYLOAD" | jq -r '.query'
  sleep 2
done
```

## Error Handling

| Code | Meaning | Action |
|------|---------|--------|
| `401` | Invalid API key | Regenerate key in profile |
| `429` | Rate limited | Wait 5 minutes, retry |
| Status `not found` | Invalid query ID | Check query ID from `/new-query` response |
| Status `waiting` / `in progress` | Still processing | Retry after 15-60 seconds |

## Setup

1. Get API key from NeuronWriter profile > "Neuron API access" tab
2. Store: `bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set NEURONWRITER_API_KEY "your_api_key"`
3. Verify: run `/list-projects` (see above)

## Resources

- **Official Docs**: https://neuronwriter.com/faq/
- **Roadmap**: https://roadmap.neuronwriter.com/p/neuron-api-HOPZZB
- **Dashboard**: https://app.neuronwriter.com/
