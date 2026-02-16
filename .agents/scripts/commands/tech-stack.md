---
description: Detect technology stacks and find sites using specific technologies
agent: Build+
mode: subagent
---

Detect the full tech stack of a URL or find sites using specific technologies. Orchestrates multiple open-source detection tools (Wappalyzer, httpx, nuclei) and optional BuiltWith API.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Operation Mode

Parse `$ARGUMENTS` to determine what to run:

- If argument is a URL: run single-site tech stack lookup
- If argument starts with "reverse": run reverse lookup to find sites using a technology
- If argument is "cache-stats" or "cache-clear": run cache management
- If argument is "help" or empty: show available commands

### Step 2: Run Appropriate Command

**Single-site lookup:**

```bash
~/.aidevops/agents/scripts/tech-stack-helper.sh lookup "$ARGUMENTS"
```

**Reverse lookup:**

```bash
~/.aidevops/agents/scripts/tech-stack-helper.sh reverse "$ARGUMENTS"
```

**Cache management:**

```bash
~/.aidevops/agents/scripts/tech-stack-helper.sh cache-stats
~/.aidevops/agents/scripts/tech-stack-helper.sh cache-clear --older-than 7
```

### Step 3: Present Results

Format the output as a clear report with:

- **Single-site lookup**: Technologies grouped by category (Frontend, Backend, Analytics, CDN, etc.) with confidence scores and provider counts
- **Reverse lookup**: List of sites using the technology with traffic tier, industry, and related technologies
- **Cache stats**: Total entries, cache size, hit rate, top cached domains

### Step 4: Offer Follow-up Actions

```text
Actions:
1. Export results to JSON/CSV
2. Run reverse lookup for detected technologies
3. Compare with competitor sites
4. Schedule periodic monitoring
5. View detailed provider reports
```

## Options

| Command | Purpose |
|---------|---------|
| `/tech-stack https://vercel.com` | Detect tech stack for URL |
| `/tech-stack vercel.com --format json` | Get JSON output |
| `/tech-stack reverse "Next.js" --traffic high` | Find high-traffic sites using Next.js |
| `/tech-stack reverse "React" --region us --industry ecommerce` | Find US ecommerce sites using React |
| `/tech-stack cache-stats` | Show cache statistics |
| `/tech-stack cache-clear --older-than 7` | Clear cache older than 7 days |

## Examples

**Single-site lookup:**

```text
User: /tech-stack https://vercel.com
AI: Analyzing tech stack for https://vercel.com...

    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    Frontend Frameworks
      React 18.2.0                    ████████████████████ 100% (4 sources)
      Next.js 13.4.1                  ████████████████████ 100% (3 sources)
    
    UI Libraries
      Tailwind CSS 3.3.0              ████████████████████ 100% (4 sources)
      Radix UI 1.0.0                  ███████████████░░░░░  75% (3 sources)
    
    Analytics
      Google Analytics 4              ████████████████████ 100% (4 sources)
      Vercel Analytics                ███████████████░░░░░  75% (3 sources)
    
    CDN & Hosting
      Vercel                          ████████████████████ 100% (4 sources)
      Cloudflare                      ████████████████████ 100% (4 sources)
    
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Total: 15 technologies detected
    Cache: Stored for 24h
    
    Actions:
    1. Export to JSON: /tech-stack vercel.com --format json
    2. Find similar sites: /tech-stack reverse "Next.js"
    3. Compare with competitor
```

**Reverse lookup:**

```text
User: /tech-stack reverse "Next.js" --traffic high
AI: Finding high-traffic sites using Next.js...

    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    Sites using Next.js (filtered: traffic=high)
    
    1. vercel.com
       Traffic: Very High (10M+ monthly)
       Industry: Developer Tools
       Also uses: React, Tailwind CSS, Vercel Analytics
    
    2. hulu.com
       Traffic: Very High (100M+ monthly)
       Industry: Streaming Media
       Also uses: React, GraphQL, AWS
    
    3. nike.com
       Traffic: Very High (500M+ monthly)
       Industry: E-commerce
       Also uses: React, Redux, Cloudflare
    
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Total: 1,247 sites found (showing top 3)
    
    Top industries: E-commerce (23%), SaaS (18%), Media (15%)
    Top regions: US (45%), EU (28%), Asia (20%)
```

**JSON output:**

```text
User: /tech-stack vercel.com --format json
AI: {
      "url": "https://vercel.com",
      "technologies": [
        {
          "name": "React",
          "version": "18.2.0",
          "category": "Frontend Framework",
          "confidence": 100,
          "providers": 4
        },
        {
          "name": "Next.js",
          "version": "13.4.1",
          "category": "Frontend Framework",
          "confidence": 100,
          "providers": 3
        }
      ],
      "cached": false,
      "timestamp": "2026-02-16T20:30:00Z"
    }
```

**Cache stats:**

```text
User: /tech-stack cache-stats
AI: Cache statistics:

    Total entries: 342
    Cache size: 2.4 MB
    Oldest entry: 14 days ago
    Newest entry: 2 hours ago
    
    Top cached domains:
    1. github.com (15 lookups)
    2. vercel.com (12 lookups)
    3. netlify.com (8 lookups)
```

## Provider Configuration

### Wappalyzer (Free, Open Source)

No API key needed. Install via npm:

```bash
npm install -g wappalyzer
```

### httpx + nuclei (Free, Open Source)

No API key needed. Install via go:

```bash
go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
go install -v github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest
```

### BuiltWith API (Commercial, Optional)

For reverse lookup and historical data:

```bash
aidevops secret set BUILTWITH_API_KEY
```

Pricing: $295/month for API access. Free tier: 100 lookups/month.

## Related

- `tools/research/tech-stack-lookup.md` - Full agent documentation
- `tools/research/wappalyzer.md` - Wappalyzer CLI integration (t1064)
- `tools/research/whatruns.md` - WhatRuns browser automation (t1065)
- `tools/research/builtwith.md` - BuiltWith API integration (t1066)
- `tools/research/httpx-nuclei.md` - HTTP fingerprinting (t1067)
