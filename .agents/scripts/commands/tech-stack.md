---
description: Detect tech stack of websites or find sites using specific technologies
agent: Build+
mode: subagent
---

Analyse website technology stacks or perform reverse lookups to find sites using specific technologies.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Operation Mode

Parse `$ARGUMENTS` to determine the operation:

- If argument starts with "reverse": reverse lookup mode (find sites using a technology)
- If argument is a URL: single-site lookup mode (detect tech stack)
- If argument is "help" or empty: show available commands

### Step 2: Run Appropriate Command

**For single-site lookup (detect tech stack):**

```bash
~/.aidevops/agents/scripts/tech-stack-helper.sh lookup "$ARGUMENTS"
```

**For reverse lookup (find sites using a technology):**

Extract technology name and optional filters from arguments:

```bash
# Parse: tech-stack reverse <tech> [--region X] [--industry Y]
tech_name=$(echo "$ARGUMENTS" | sed 's/^reverse //' | awk '{print $1}')
region=$(echo "$ARGUMENTS" | grep -oP '(?<=--region )\S+' || echo "")
industry=$(echo "$ARGUMENTS" | grep -oP '(?<=--industry )\S+' || echo "")

# Build command with optional filters
cmd="~/.aidevops/agents/scripts/tech-stack-helper.sh reverse \"$tech_name\""
[[ -n "$region" ]] && cmd="$cmd --region \"$region\""
[[ -n "$industry" ]] && cmd="$cmd --industry \"$industry\""

eval "$cmd"
```

**For cached report:**

```bash
~/.aidevops/agents/scripts/tech-stack-helper.sh report "$ARGUMENTS"
```

### Step 3: Present Results

Format the output as a clear report with:

- Detected technologies (frameworks, CMS, analytics, CDN, hosting, etc.)
- Confidence scores for each detection
- Technology versions where available
- Links to technology documentation

For reverse lookups:
- List of sites using the specified technology
- Site metadata (traffic tier, region, industry)
- Technology usage patterns

### Step 4: Offer Follow-up Actions

```text
Actions:
1. Analyse another URL
2. Reverse lookup for a specific technology
3. View cached report
4. Export results to JSON
5. Compare tech stacks across multiple sites
```

## Options

| Command | Purpose |
|---------|---------|
| `/tech-stack https://example.com` | Detect tech stack of a single site |
| `/tech-stack reverse react` | Find sites using React |
| `/tech-stack reverse wordpress --region US` | Find WordPress sites in US |
| `/tech-stack reverse nextjs --industry ecommerce` | Find Next.js sites in e-commerce |
| `/tech-stack reverse tailwind --region EU --industry saas` | Find Tailwind sites in EU SaaS |
| `/tech-stack report https://example.com` | View cached report |

## Examples

**Single-site lookup:**

```text
User: /tech-stack https://example.com
AI: Detecting tech stack for https://example.com...

    Frontend Framework: React 18.2.0 (high confidence)
    UI Library: Tailwind CSS 3.3.0 (high confidence)
    State Management: Redux 4.2.0 (medium confidence)
    Build Tool: Webpack 5.88.0 (high confidence)
    CDN: Cloudflare (high confidence)
    Analytics: Google Analytics 4 (high confidence)
    Hosting: Vercel (medium confidence)

    Full report cached. Use `/tech-stack report https://example.com` to view again.
```

**Reverse lookup:**

```text
User: /tech-stack reverse nextjs --region US --industry saas
AI: Finding sites using Next.js in US SaaS sector...

    Found 1,247 sites using Next.js:

    Top Sites:
    1. vercel.com - High traffic, US, SaaS
    2. notion.so - High traffic, US, SaaS
    3. linear.app - Medium traffic, US, SaaS
    4. cal.com - Medium traffic, US, SaaS
    5. resend.com - Low traffic, US, SaaS

    Filters applied:
    - Region: US
    - Industry: SaaS
    - Technology: Next.js

    Use `/tech-stack <url>` to analyse specific sites.
```

## Related

- `tools/research/tech-stack-lookup.md` - Full documentation
- `services/research/builtwith.md` - BuiltWith API integration
- `services/research/wappalyzer.md` - Wappalyzer integration
