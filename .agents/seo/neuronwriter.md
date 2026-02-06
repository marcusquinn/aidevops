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
- **API**: `https://app.neuronwriter.com/neuron-api/0.5/writer`
- **Auth**: API key in `X-API-KEY` header, stored in `~/.config/aidevops/mcp-env.sh` as `NEURONWRITER_API_KEY`
- **Plan**: Gold plan or higher required
- **Docs**: https://neuronwriter.com/faqs/neuronwriter-api-how-to-use/
- **No MCP required** - uses curl directly

**API requests consume monthly limits** (same cost as using the NeuronWriter UI).

<!-- AI-CONTEXT-END -->

## Authentication

```bash
source ~/.config/aidevops/mcp-env.sh
```

## API Endpoints

All endpoints use POST. All require the `X-API-KEY` header.

### List Projects

```bash
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/list-projects" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json"
```

Response:

```json
[
  {"project": "ed0b47151fb35b02", "name": "My SEO Project", "language": "English", "engine": "google.co.uk"},
  {"project": "e6a3198027aa1b96", "name": "E-commerce Content", "language": "English", "engine": "google.co.uk"}
]
```

### Create New Query (`/new-query`)

Creates a content writer query for a keyword. Takes ~60 seconds to process.

```bash
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/new-query" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ed0b47151fb35b02",
    "keyword": "trail running shoes",
    "engine": "google.co.uk",
    "language": "English"
  }'
```

| Param | Description |
|-------|-------------|
| `project` | Project ID from project URL or `/list-projects` |
| `keyword` | Target keyword to analyse |
| `engine` | Search engine (e.g. `google.com`, `google.co.uk`) |
| `language` | Content language (e.g. `English`) |

Response:

```json
{
  "query": "32dee2a89374a722",
  "query_url": "https://app.neuronwriter.com/analysis/view/32dee2a89374a722",
  "share_url": "https://app.neuronwriter.com/analysis/share/32dee2a89374a722/...",
  "readonly_url": "https://app.neuronwriter.com/analysis/content-preview/32dee2a89374a722/..."
}
```

### Get Query Recommendations (`/get-query`)

Retrieves SEO recommendations after processing (~60s after `/new-query`).

```bash
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/get-query" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"query": "32dee2a89374a722"}'
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

### List Queries (`/list-queries`)

Filter queries within a project.

```bash
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/list-queries" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ed0b47151fb35b02",
    "status": "ready",
    "source": "neuron-api"
  }'
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

### Get Content (`/get-content`)

Retrieve the last saved content revision for a query.

```bash
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/get-content" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"query": "32dee2a89374a722", "revision_type": "all"}'
```

| Param | Description |
|-------|-------------|
| `query` | Query ID |
| `revision_type` | `manual` (default) or `all` (includes autosave) |

Response:

| Key | Description |
|-----|-------------|
| `content` | HTML content |
| `title` | Page title |
| `description` | Meta description |
| `created` | Revision timestamp |
| `type` | `manual` or `autosave` |

### Import Content (`/import-content`)

Push HTML content into the NeuronWriter editor. Creates a new content revision.

```bash
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/import-content" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "32dee2a89374a722",
    "html": "<h1>Your Article Title</h1><p>Article content...</p>",
    "title": "Your Article Title",
    "description": "Meta description for the article."
  }'
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

Response: `{"status": "ok", "content_score": 25}`

### Evaluate Content (`/evaluate-content`)

Same parameters and response as `/import-content`, but does **not** save a revision. Use this to score content without modifying the editor.

```bash
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/evaluate-content" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "32dee2a89374a722",
    "html": "<h1>Your Article Title</h1><p>Article content...</p>"
  }'
```

## Common Workflows

### Create Query and Poll for Results

```bash
source ~/.config/aidevops/mcp-env.sh

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

# 2. Poll until ready (check every 15s, max 5 min)
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

### Score Existing Content Against a Query

```bash
source ~/.config/aidevops/mcp-env.sh

curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/evaluate-content" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "EXISTING_QUERY_ID",
    "url": "https://example.com/your-article"
  }' | jq '.content_score'
```

### Bulk Keyword Analysis

```bash
source ~/.config/aidevops/mcp-env.sh

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
2. Store securely:

```bash
bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set NEURONWRITER_API_KEY "your_api_key"
```

3. Verify:

```bash
source ~/.config/aidevops/mcp-env.sh
curl -s -X POST "https://app.neuronwriter.com/neuron-api/0.5/writer/list-projects" \
  -H "X-API-KEY: $NEURONWRITER_API_KEY" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" | jq .
```

## Resources

- **Official Docs**: https://neuronwriter.com/faqs/neuronwriter-api-how-to-use/
- **Roadmap**: https://roadmap.neuronwriter.com/p/neuron-api-HOPZZB
- **Dashboard**: https://app.neuronwriter.com/
- **Plan Required**: Gold or higher
