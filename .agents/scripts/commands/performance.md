---
description: Comprehensive web performance analysis (CWV, network, accessibility)
agent: Build+
mode: subagent
---

Analyze web performance for $ARGUMENTS using Chrome DevTools MCP.

## Prerequisites

- `chrome-devtools-mcp` installed (`npx chrome-devtools-mcp@latest --version`)
- Read `tools/performance/performance.md` for thresholds and fix patterns.

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--categories=...` | all | performance, accessibility, network |
| `--device=...` | mobile | mobile or desktop |
| `--iterations=N` | 3 | Runs to average |
| `--compare=FILE` | — | Compare against baseline.json |
| `--local` | — | Assume localhost URL |

## Run Analysis

Execute in order via Chrome DevTools MCP:
1. **Lighthouse Audit** (scores)
2. **Core Web Vitals** (FCP, LCP, CLS, FID, TTFB)
3. **Network Analysis** (third-party, chains, sizes)
4. **Accessibility** (WCAG compliance)

## Report Format

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
1. **Issue** — File: `path/to/file` (use `rg` to find) — Fix: recommendation

### Network Dependencies
- X third-party scripts; longest chain: X requests; total blocking time: Xms

### Accessibility
- Score: X/100 — X issues found
```

For each issue: **What** (problem), **Where** (file), **How** (fix), **Impact** (improvement).

## Examples

```bash
/performance https://example.com                                    # full audit
/performance http://localhost:3000 --local                          # local dev
/performance https://example.com --device=mobile                    # mobile only
/performance https://example.com --compare=baseline.json            # diff baseline
/performance https://example.com --categories=performance,accessibility
```

## Related

- `tools/performance/performance.md` (subagent)
- `tools/browser/pagespeed.md` (PageSpeed Insights)
- `tools/browser/chrome-devtools.md` (Chrome DevTools MCP)
