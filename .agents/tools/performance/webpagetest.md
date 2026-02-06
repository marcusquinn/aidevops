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

# WebPageTest Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Real-world performance testing from global locations with filmstrip, waterfall, and Core Web Vitals
- **API Base**: `https://www.webpagetest.org`
- **API Key**: Required for public instance. Get from https://www.webpagetest.org/signup
- **Credential Storage**: `~/.config/aidevops/credentials.sh` as `WEBPAGETEST_API_KEY`
- **Node.js Wrapper**: `npm install -g webpagetest` (CLI + API)
- **Docs**: https://docs.webpagetest.org/api/reference/
- **Related**: `tools/performance/performance.md`, `tools/browser/pagespeed.md`

<!-- AI-CONTEXT-END -->

## Overview

WebPageTest (by Catchpoint) provides real-browser performance testing from 40+ global locations. Unlike synthetic Lighthouse audits, WebPageTest runs tests on real hardware with real network conditions, producing:

- **Filmstrip view** - visual loading progression frame by frame
- **Waterfall charts** - request-level timing for every resource
- **Core Web Vitals** - LCP, CLS, INP, TTFB from real browsers
- **Video capture** - visual comparison of page loads
- **Multi-run median** - statistical accuracy across multiple test runs
- **Connection throttling** - Cable, 3G, 4G, LTE, custom profiles
- **Technology detection** - Wappalyzer integration identifies tech stack
- **Accessibility** - Axe-core testing built in

## Setup

### API Key

```bash
# Sign up at https://www.webpagetest.org/signup
# Store key securely
echo 'export WEBPAGETEST_API_KEY="your-key-here"' >> ~/.config/aidevops/credentials.sh
source ~/.config/aidevops/credentials.sh
```

### Node.js CLI (Optional)

```bash
npm install -g webpagetest

# Test connectivity
webpagetest status --key "$WEBPAGETEST_API_KEY"
```

## API Usage

### Run a Test

```bash
# Basic test (JSON response)
curl -s -X POST \
  "https://www.webpagetest.org/runtest.php?url=https://example.com&f=json&runs=3&video=1&lighthouse=1" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
```

Response returns a `testId` and URLs for results:

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

### Check Test Status

```bash
# Poll until statusCode == 200
curl -s "https://www.webpagetest.org/testStatus.php?test=$TEST_ID&f=json"
```

Status codes: `100` = started, `101` = queued, `200` = complete, `4xx` = error.

### Retrieve Results

```bash
# Full results with request breakdown
curl -s "https://www.webpagetest.org/jsonResult.php?test=$TEST_ID&requests=1&breakdown=1&domains=1"
```

Key metrics in the response at `data.median.firstView`:

| Field | Metric |
|-------|--------|
| `TTFB` | Time to First Byte (ms) |
| `firstContentfulPaint` | First Contentful Paint (ms) |
| `chromeUserTiming.LargestContentfulPaint` | LCP (ms) |
| `chromeUserTiming.CumulativeLayoutShift` | CLS |
| `TotalBlockingTime` | Total Blocking Time (ms) |
| `SpeedIndex` | Speed Index |
| `fullyLoaded` | Fully Loaded Time (ms) |
| `bytesIn` | Total bytes downloaded |
| `requests` | Total request count |
| `render` | Start Render time (ms) |
| `domContentLoadedEventStart` | DCL (ms) |
| `loadTime` | Load Time (ms) |

### Check Remaining Balance

```bash
curl -s "https://www.webpagetest.org/testBalance.php" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
# Returns: {"data":{"remaining":1175}}
```

### List Available Locations

```bash
curl -s "https://www.webpagetest.org/getLocations.php?f=json" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY" | jq '.data | keys'
```

### Cancel a Test

```bash
curl -s "https://www.webpagetest.org/cancelTest.php?test=$TEST_ID" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
```

## Common Test Configurations

### Desktop - Cable (Default)

```bash
curl -s -X POST \
  "https://www.webpagetest.org/runtest.php?url=https://example.com&f=json&runs=3&video=1&location=ec2-us-east-1:Chrome.Cable" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
```

### Mobile - 4G

```bash
curl -s -X POST \
  "https://www.webpagetest.org/runtest.php?url=https://example.com&f=json&runs=3&video=1&mobile=1&location=ec2-us-east-1:Chrome.4G" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
```

### With Lighthouse

```bash
curl -s -X POST \
  "https://www.webpagetest.org/runtest.php?url=https://example.com&f=json&lighthouse=1" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
```

### First View Only (Faster)

```bash
curl -s -X POST \
  "https://www.webpagetest.org/runtest.php?url=https://example.com&f=json&runs=3&fvonly=1" \
  -H "X-WPT-API-KEY: $WEBPAGETEST_API_KEY"
```

### From Specific Region

Common locations:

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

## Node.js CLI Usage

```bash
# Install
npm install -g webpagetest

# Run test
webpagetest test https://example.com \
  --key "$WEBPAGETEST_API_KEY" \
  --location ec2-us-east-1:Chrome.Cable \
  --runs 3 \
  --first \
  --video \
  --lighthouse \
  --poll 10 \
  --reporter json

# Get results
webpagetest results $TEST_ID --key "$WEBPAGETEST_API_KEY" --reporter json

# Check status
webpagetest status $TEST_ID --key "$WEBPAGETEST_API_KEY"

# List locations
webpagetest locations --key "$WEBPAGETEST_API_KEY"

# Check balance
webpagetest testBalance --key "$WEBPAGETEST_API_KEY"
```

## Scripted Tests

WebPageTest supports multi-step scripted tests for authenticated pages, SPAs, and complex flows:

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

## Workflow: Full Performance Audit

1. **Run test** with 3 runs, video, and Lighthouse enabled
2. **Poll status** until `statusCode == 200`
3. **Retrieve results** with `requests=1&breakdown=1&domains=1`
4. **Extract key metrics** from `data.median.firstView`
5. **Analyze waterfall** for bottlenecks (long TTFB, render-blocking resources, large assets)
6. **Review filmstrip** for visual loading progression
7. **Check Lighthouse** scores if enabled
8. **Compare** against Core Web Vitals thresholds

## Workflow: Before/After Comparison

1. Run baseline test, save `testId`
2. Make performance changes
3. Run comparison test with same location/connectivity
4. Compare median metrics:
   - LCP delta
   - TTFB delta
   - Speed Index delta
   - Total Blocking Time delta
   - Bytes transferred delta
   - Request count delta

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
