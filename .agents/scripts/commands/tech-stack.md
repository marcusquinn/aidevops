---
description: Detect technology stacks and find sites using specific technologies
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Detect the full tech stack of a URL or find sites using specific technologies. Orchestrates Wappalyzer, httpx, nuclei, and optional BuiltWith API.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Operation Mode

Parse `$ARGUMENTS`:

- URL → single-site tech stack lookup
- Starts with `reverse` → reverse lookup (find sites using a technology)
- `cache-stats` or `cache-clear` → cache management
- `help` or empty → show available commands

### Step 2: Run Command

**Single-site lookup:**

```bash
~/.aidevops/agents/scripts/tech-stack-helper.sh lookup "$ARGUMENTS"
```

**Reverse lookup** — parse technology name and optional filters (portable shell, no `eval`/PCRE):

```bash
# Parse: tech-stack reverse <tech> [--region X] [--industry Y] [--traffic Z]
# Use awk with ' --' delimiter to capture full multi-word tech names (e.g. "Google Analytics")
tech_name=$(echo "${ARGUMENTS#reverse }" | awk -F ' --' '{print $1}')
region=$(echo "$ARGUMENTS" | sed -n 's/.*--region \([^ ]*\).*/\1/p')
industry=$(echo "$ARGUMENTS" | sed -n 's/.*--industry \([^ ]*\).*/\1/p')
traffic=$(echo "$ARGUMENTS" | sed -n 's/.*--traffic \([^ ]*\).*/\1/p')

# Build command using a bash array — never use eval for dynamic command construction
cmd_array=(~/.aidevops/agents/scripts/tech-stack-helper.sh reverse "$tech_name")
[[ -n "$region" ]] && cmd_array+=(--region "$region")
[[ -n "$industry" ]] && cmd_array+=(--industry "$industry")
[[ -n "$traffic" ]] && cmd_array+=(--traffic "$traffic")

"${cmd_array[@]}"
```

**Cache management:**

```bash
~/.aidevops/agents/scripts/tech-stack-helper.sh cache-stats
~/.aidevops/agents/scripts/tech-stack-helper.sh cache-clear --older-than 7
```

### Step 3: Present Results and Offer Follow-ups

Format output by operation type: **Single-site** — technologies grouped by category (Frontend, Backend, Analytics, CDN, etc.) with confidence scores and provider counts. **Reverse** — sites using the technology with traffic tier, industry, and related technologies. **Cache stats** — total entries, cache size, hit rate, top cached domains.

Offer follow-ups: export to JSON/CSV, reverse lookup for detected technologies, competitor comparison, periodic monitoring, detailed provider reports.

## Usage

| Command | Purpose |
|---------|---------|
| `/tech-stack https://vercel.com` | Detect tech stack for URL |
| `/tech-stack vercel.com --format json` | JSON output |
| `/tech-stack reverse "Next.js" --traffic high` | Find high-traffic Next.js sites |
| `/tech-stack reverse "React" --region us --industry ecommerce` | Find US ecommerce React sites |
| `/tech-stack cache-stats` | Show cache statistics |
| `/tech-stack cache-clear --older-than 7` | Clear cache older than 7 days |

## Provider Configuration

| Provider | Cost | Install |
|----------|------|---------|
| Wappalyzer | Free, open source | `npm install -g wappalyzer` |
| httpx | Free, open source | `go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest` |
| nuclei | Free, open source | `go install -v github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest` |
| BuiltWith API | $295/month; free tier: 100 lookups/month | `aidevops secret set BUILTWITH_API_KEY` |

BuiltWith is optional — required for reverse lookup and historical data.

## Related

- `tools/research/tech-stack-lookup.md` — full agent documentation
- `tools/research/wappalyzer.md` — Wappalyzer CLI integration (t1064)
- `tools/research/whatruns.md` — WhatRuns browser automation (t1065)
- `tools/research/builtwith.md` — BuiltWith API integration (t1066)
- `tools/research/httpx-nuclei.md` — HTTP fingerprinting (t1067)
