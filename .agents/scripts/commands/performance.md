---
description: Run comprehensive web performance analysis (Core Web Vitals, network, accessibility)
agent: Build+
mode: subagent
---

Analyze web performance for the specified URL using Chrome DevTools MCP.

URL/Target: $ARGUMENTS

## Workflow

### Step 1: Parse Arguments

```text
Default: Full audit (performance + accessibility + network)
Options:
  --categories=performance,accessibility,network  Specific categories
  --device=mobile|desktop         Device emulation (default: mobile)
  --iterations=N                  Number of runs for averaging (default: 3)
  --compare=baseline.json         Compare against baseline
  --local                         Assume localhost URL
```

### Step 2: Check Prerequisites

```bash
# Verify Chrome DevTools MCP is available
which npx && npx chrome-devtools-mcp@latest --version || echo "Install: npm i -g chrome-devtools-mcp"
```

### Step 3: Read Performance Subagent

Read `~/.aidevops/agents/tools/performance/performance.md` for:
- Core Web Vitals thresholds
- Common issues and fixes
- Actionable output format

### Step 4: Run Analysis

Using Chrome DevTools MCP:

1. **Lighthouse Audit** - Performance, accessibility, best practices, SEO scores
2. **Core Web Vitals** - FCP, LCP, CLS, FID, TTFB measurements
3. **Network Analysis** - Third-party scripts, request chains, bundle sizes
4. **Accessibility Check** - WCAG compliance issues

### Step 5: Generate Report

Output in actionable format:

```markdown
## Performance Report: [URL]

### Core Web Vitals
| Metric | Value | Status | Target |
|--------|-------|--------|--------|
| LCP | X.Xs | GOOD/NEEDS WORK/POOR | <2.5s |
| FID | Xms | GOOD/NEEDS WORK/POOR | <100ms |
| CLS | X.XX | GOOD/NEEDS WORK/POOR | <0.1 |
| TTFB | Xms | GOOD/NEEDS WORK/POOR | <800ms |

### Top Issues (Priority Order)
1. **Issue** - Description
   - File: `path/to/file:line`
   - Fix: Specific recommendation

### Network Dependencies
- X third-party scripts
- Longest chain: X requests
- Total blocking time: Xms

### Accessibility
- Score: X/100
- X issues found
```

### Step 6: Provide Fixes

For each issue, provide:
1. **What**: The specific problem
2. **Where**: File path and line number (if in repo)
3. **How**: Code snippet or configuration change
4. **Impact**: Expected improvement

## Examples

```bash
# Full audit of production site
/performance https://example.com

# Local dev server
/performance http://localhost:3000 --local

# Mobile-specific audit
/performance https://example.com --device=mobile

# Compare against baseline
/performance https://example.com --compare=baseline.json

# Specific categories only
/performance https://example.com --categories=performance,accessibility
```

## Related

- `tools/performance/performance.md` - Full performance subagent
- `tools/browser/pagespeed.md` - PageSpeed Insights integration
- `tools/browser/chrome-devtools.md` - Chrome DevTools MCP
