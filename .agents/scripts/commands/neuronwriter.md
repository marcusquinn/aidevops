---
description: NeuronWriter content optimization - analyze keywords, score content, get NLP recommendations
agent: Build+
mode: subagent
---

Optimize content for SEO using NeuronWriter's NLP analysis API.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Parse Arguments

Parse `$ARGUMENTS` to determine the action:

```text
/neuronwriter analyze <keyword> [options]     → Create query + get NLP recommendations
/neuronwriter score <query-id> <url-or-html>  → Score content against a query
/neuronwriter import <query-id> <url-or-html> → Import content into NeuronWriter editor
/neuronwriter get <query-id>                  → Get recommendations for existing query
/neuronwriter content <query-id>              → Get saved content from editor
/neuronwriter projects                        → List all projects
/neuronwriter queries <project-id> [options]  → List queries in a project
/neuronwriter status                          → Check API key configuration
```

If only a keyword is provided (no subcommand), default to `analyze`.

### Step 2: Check API Key

```bash
source ~/.config/aidevops/mcp-env.sh
if [[ -z "$NEURONWRITER_API_KEY" ]]; then
  echo "NEURONWRITER_API_KEY not configured." >&2
  echo "Set it with: bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set NEURONWRITER_API_KEY \"your_key\"" >&2
  echo "Get your key from: NeuronWriter profile > Neuron API access tab" >&2
  echo "Requires Gold plan or higher." >&2
  exit 1
fi
```

### Step 3: Read the NeuronWriter Subagent

Read `seo/neuronwriter.md` for full API reference, then execute the appropriate endpoint.

### Step 4: Execute Action

**For `analyze` (default):**

1. List projects to find the right one (or use `--project <id>` if provided)
2. Call `/new-query` with the keyword
3. Poll `/get-query` every 15 seconds until `status == "ready"` (max 5 minutes)
4. Present NLP recommendations in a structured format

**For `score`:**

1. Call `/evaluate-content` with the query ID and URL or HTML
2. Report the content score

**For `import`:**

1. Call `/import-content` with the query ID and URL or HTML
2. Report the content score and editor URL

**For `get`:**

1. Call `/get-query` with the query ID
2. Present recommendations (terms, ideas, competitors)

**For `content`:**

1. Call `/get-content` with the query ID
2. Return the saved HTML content, title, and description

**For `projects`:**

1. Call `/list-projects`
2. Display project names, IDs, languages, and engines

**For `queries`:**

1. Call `/list-queries` with the project ID
2. Optionally filter by `--status`, `--keyword`, `--tag`

### Step 5: Report Results

**For `analyze`, present recommendations as:**

```text
Keyword: "trail running shoes"
Query ID: 32dee2a89374a722
Query URL: https://app.neuronwriter.com/analysis/view/32dee2a89374a722

NLP Terms (Content):
  - trail running shoes (use 8-12 times)
  - running shoe (use 3-5 times)
  - trail runners (use 2-4 times)
  ...

Suggested Headings (H2):
  - Best Trail Running Shoes for 2025
  - How to Choose Trail Running Shoes
  ...

Content Ideas:
  - What makes trail running shoes different from road shoes?
  - How often should you replace trail running shoes?
  ...

Competitors (Top 5):
  1. runnersworld.com - Score: 87
  2. rei.com - Score: 82
  ...

Word Count Target: 2,500-3,000
```

**For `score` / `import`:**

```text
Content Score: 72/100
Query: 32dee2a89374a722
```

## Options

| Option | Description |
|--------|-------------|
| `--project <id>` | Project ID (skips project selection) |
| `--engine <engine>` | Search engine (default: `google.com`) |
| `--language <lang>` | Content language (default: `English`) |

## Examples

**Analyze a keyword:**

```text
/neuronwriter trail running shoes
```

**Analyze with specific project and engine:**

```text
/neuronwriter analyze "best running gear" --project ed0b47151fb35b02 --engine google.co.uk
```

**Score a URL against an existing query:**

```text
/neuronwriter score 32dee2a89374a722 https://example.com/running-shoes
```

**Import content into the editor:**

```text
/neuronwriter import 32dee2a89374a722 https://example.com/running-shoes
```

**Get recommendations for an existing query:**

```text
/neuronwriter get 32dee2a89374a722
```

**List all projects:**

```text
/neuronwriter projects
```

**List ready queries in a project:**

```text
/neuronwriter queries ed0b47151fb35b02 --status ready
```

**Check API key status:**

```text
/neuronwriter status
```

## Related

- `seo/neuronwriter.md` - Full API reference and authentication details
- NeuronWriter requires Gold plan or higher for API access
- API requests consume the same monthly limits as the NeuronWriter UI
