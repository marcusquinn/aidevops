---
description: Run comprehensive web performance analysis (Core Web Vitals, network, accessibility)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Analyze web performance for the specified URL using Chrome DevTools MCP.

URL/Target: $ARGUMENTS

**Prerequisites:** Verify Chrome DevTools MCP: `which npx && npx chrome-devtools-mcp@latest --version || echo "Install: npm i -g chrome-devtools-mcp"`. Read `~/.aidevops/agents/tools/performance/performance.md` for CWV thresholds, common issues, and fix patterns.

Run in order: Lighthouse audit → Core Web Vitals (FCP, LCP, CLS, FID, TTFB) → Network analysis (third-party scripts, request chains, bundle sizes) → Accessibility (WCAG).

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--categories=performance,accessibility,network` | all | Specific categories |
| `--device=mobile\|desktop` | mobile | Device emulation |
| `--iterations=N` | 3 | Runs to average |
| `--compare=baseline.json` | — | Compare against baseline |
| `--local` | — | Assume localhost URL |

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
1. **Issue** — File: `path/to/file` — Fix: specific recommendation

### Network Dependencies
- X third-party scripts; longest chain: X requests; total blocking time: Xms

### Accessibility
- Score: X/100 — X issues found
```

For each issue: **What** (problem), **Where** (file path), **How** (code/config fix), **Impact** (expected improvement).

## Examples

```bash
/performance https://example.com                          # full audit
/performance http://localhost:3000 --local                # local dev
/performance https://example.com --device=mobile          # mobile only
/performance https://example.com --compare=baseline.json  # diff baseline
/performance https://example.com --categories=performance,accessibility
```

## Related

- `tools/performance/performance.md` — full performance subagent
- `tools/browser/pagespeed.md` — PageSpeed Insights integration
- `tools/browser/chrome-devtools.md` — Chrome DevTools MCP
