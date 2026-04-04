---
description: WebPageTest API integration - performance testing, filmstrip, waterfall, Core Web Vitals
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WebPageTest Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Real-browser performance testing from 40+ global locations — filmstrip, waterfall, Core Web Vitals
- **API Base**: `https://www.webpagetest.org`
- **API Key**: Required. Sign up: <https://www.webpagetest.org/signup>
- **Credential Storage**: `~/.config/aidevops/credentials.sh` as `WEBPAGETEST_API_KEY`
- **Node.js CLI**: `npm install -g webpagetest` (optional wrapper)
- **Docs**: <https://docs.webpagetest.org/api/reference/>
- **Related**: `tools/performance/performance.md`, `tools/browser/pagespeed.md`

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Store API key
echo 'export WEBPAGETEST_API_KEY="your-key-here"' >> ~/.config/aidevops/credentials.sh
source ~/.config/aidevops/credentials.sh
```

## API Usage

All examples use `$WEBPAGETEST_API_KEY` via the `X-WPT-API-KEY` header. Base URL: `https://www.webpagetest.org`.

### Run a Test

```bash
curl -s -X POST \
  "https://www.webpagetest.org/runtest.php?url=https://example.com&f=json&runs=3&video=1&lighthouse=1" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
```

Response:

```json
{
  "statusCode": 200,
  "data": {
    "testId": "240101_Ab1C_abc123",
    "jsonUrl": "https://www.webpagetest.org/jsonResult.php?test=240101_Ab1C_abc123",
    "userUrl": "https://www.webpagetest.org/result/240101_Ab1C_abc123/"
  }
}
```

### Check Status / Retrieve Results / Balance / Locations / Cancel

```bash
# Poll until statusCode == 200 (100=started, 101=queued, 4xx=error)
curl -s "https://www.webpagetest.org/testStatus.php?test=$TEST_ID&f=json"

# Full results with request breakdown
curl -s "https://www.webpagetest.org/jsonResult.php?test=$TEST_ID&requests=1&breakdown=1&domains=1"

# Remaining test balance
curl -s "https://www.webpagetest.org/testBalance.php" -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"

# Available locations
curl -s "https://www.webpagetest.org/getLocations.php?f=json" -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY" | jq '.data | keys'

# Cancel a test
curl -s "https://www.webpagetest.org/cancelTest.php?test=$TEST_ID" -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
```

### Result Metrics

Key fields at `data.median.firstView`:

| Field | Metric |
|-------|--------|
| `TTFB` | Time to First Byte (ms) |
| `firstContentfulPaint` | FCP (ms) |
| `chromeUserTiming.LargestContentfulPaint` | LCP (ms) |
| `chromeUserTiming.CumulativeLayoutShift` | CLS |
| `chromeUserTiming.InteractionToNextPaint` | INP (ms) — lab support varies |
| `TotalBlockingTime` | TBT (ms) |
| `SpeedIndex` | Speed Index |
| `fullyLoaded` | Fully Loaded (ms) |
| `bytesIn` | Total bytes |
| `requests` | Request count |
| `render` | Start Render (ms) |
| `domContentLoadedEventStart` | DCL (ms) |
| `loadTime` | Load Time (ms) |

## Test Configuration

Append parameters to the `runtest.php` URL. Key parameters:

| Parameter | Effect | Example |
|-----------|--------|---------|
| `runs=N` | Number of test runs | `runs=3` |
| `video=1` | Enable video capture | |
| `lighthouse=1` | Run Lighthouse audit | |
| `mobile=1` | Mobile emulation | |
| `fvonly=1` | First view only (faster) | |
| `location=ID:Browser.Profile` | Test location + connectivity | `ec2-us-east-1:Chrome.Cable` |

### Locations

| Location ID | Region |
|-------------|--------|
| `ec2-us-east-1` | Virginia, USA |
| `ec2-us-west-1` | California, USA |
| `ec2-eu-west-1` | Ireland |
| `ec2-eu-central-1` | Frankfurt, Germany |
| `ec2-ap-southeast-1` | Singapore |
| `ec2-ap-northeast-1` | Tokyo, Japan |
| `ec2-sa-east-1` | Sao Paulo, Brazil |
| `ec2-ap-south-1` | Mumbai, India |
| `Dulles` | Dulles, VA (physical) |

### Connection Profiles

| Profile | Down | Up | RTT | Use Case |
|---------|------|-----|-----|----------|
| `Cable` | 5 Mbps | 1 Mbps | 28ms | Default desktop |
| `DSL` | 1.5 Mbps | 384 Kbps | 50ms | Slow broadband |
| `FIOS` | 20 Mbps | 5 Mbps | 4ms | Fast broadband |
| `4G` | 9 Mbps | 9 Mbps | 170ms | Mobile 4G |
| `LTE` | 12 Mbps | 12 Mbps | 70ms | Mobile LTE |
| `3G` | 1.6 Mbps | 768 Kbps | 300ms | Mobile 3G |
| `3GSlow` | 400 Kbps | 400 Kbps | 400ms | Slow mobile |
| `Dial` | 49 Kbps | 30 Kbps | 120ms | Dial-up |
| `Native` | No shaping | - | - | Raw connection |

## Node.js CLI

Optional alternative to curl. Install: `npm install -g webpagetest`.

```bash
# Run test (polls until complete)
webpagetest test https://example.com \
  --key "$WEBPAGETEST_API_KEY" \
  --location ec2-us-east-1:Chrome.Cable \
  --runs 3 --first --video --lighthouse \
  --poll 10 --reporter json

# Other commands
webpagetest results $TEST_ID --key "$WEBPAGETEST_API_KEY" --reporter json
webpagetest status $TEST_ID --key "$WEBPAGETEST_API_KEY"
webpagetest locations --key "$WEBPAGETEST_API_KEY"
webpagetest testBalance --key "$WEBPAGETEST_API_KEY"
```

## Scripted Tests

Multi-step tests for authenticated pages, SPAs, and complex flows:

```text
// Navigate and wait for element
navigate	https://example.com/login
setValue	name=email	user@example.com
setValue	name=password	password123
submitForm	name=loginForm
waitForComplete
navigate	https://example.com/dashboard
```

Pass via the `script` parameter:

```bash
curl -s -X POST \
  "https://www.webpagetest.org/runtest.php?f=json" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY" \
  --data-urlencode "script=navigate	https://example.com/login
setValue	name=email	user@example.com
submitForm	name=loginForm
waitForComplete
navigate	https://example.com/dashboard"
```

## Workflows

### Full Performance Audit

1. Run test with `runs=3&video=1&lighthouse=1`
2. Poll status until `statusCode == 200`
3. Retrieve results with `requests=1&breakdown=1&domains=1`
4. Extract metrics from `data.median.firstView`
5. Analyse waterfall for bottlenecks (long TTFB, render-blocking resources, large assets)
6. Review filmstrip for visual loading progression
7. Check Lighthouse scores if enabled
8. Compare against Core Web Vitals thresholds

### Before/After Comparison

1. Run baseline test, save `testId`
2. Make performance changes
3. Run comparison test with same location/connectivity
4. Compare median metrics: LCP, TTFB, Speed Index, TBT, bytes transferred, request count

## When to Use WebPageTest vs Other Tools

| Scenario | Tool |
|----------|------|
| Quick local audit | `performance.md` (Chrome DevTools MCP) |
| Google PageSpeed score | `pagespeed.md` (PageSpeed Insights API) |
| Real-world multi-location testing | **WebPageTest** |
| Filmstrip/waterfall analysis | **WebPageTest** |
| Connection throttling comparison | **WebPageTest** |
| CI/CD performance gates | `pagespeed.md` or **WebPageTest** |
| Authenticated page testing | **WebPageTest** (scripted tests) |
| Technology stack detection | **WebPageTest** (Wappalyzer) |

## Related Subagents

- `tools/performance/performance.md` - Chrome DevTools MCP for local performance analysis
- `tools/browser/pagespeed.md` - PageSpeed Insights and Lighthouse CLI
- `tools/browser/chrome-devtools.md` - Chrome DevTools MCP integration
- `seo/seo-audit-skill.md` - SEO audit framework (references WebPageTest)
