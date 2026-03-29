---
description: CapSolver CAPTCHA solving with Crawl4AI
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

# CapSolver + Crawl4AI Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- Setup: `./.agents/scripts/crawl4ai-helper.sh capsolver-setup`
- API key: `export CAPSOLVER_API_KEY="CAP-xxxxx"` (from dashboard.capsolver.com)
- Crawl: `./.agents/scripts/crawl4ai-helper.sh captcha-crawl URL captcha_type site_key`
- Python: `import capsolver; capsolver.api_key = "KEY"; solution = capsolver.solve({...})`
- Config: `configs/capsolver-config.json`, `configs/capsolver-example.py`

<!-- AI-CONTEXT-END -->

## Supported CAPTCHA Types

| Type | Price | Time |
|------|-------|------|
| reCAPTCHA v2 | $0.5/1000 | <9s |
| reCAPTCHA v3 | $0.5/1000 | <3s |
| reCAPTCHA v2 Enterprise | $1/1000 | <9s |
| reCAPTCHA v3 Enterprise (≥0.9 score) | $3/1000 | <3s |
| Cloudflare Turnstile | $3/1000 | <3s |
| Cloudflare Challenge | Contact | <10s |
| AWS WAF | Contact | <5s |
| GeeTest v3/v4 | $0.5/1000 | <5s |
| Image-to-Text OCR | $0.4/1000 | <1s |

## Setup

```bash
./.agents/scripts/crawl4ai-helper.sh install
./.agents/scripts/crawl4ai-helper.sh docker-setup
./.agents/scripts/crawl4ai-helper.sh capsolver-setup
export CAPSOLVER_API_KEY="CAP-xxxxxxxxxxxxxxxxxxxxx"
```

**Browser extension alternative**: Install [CapSolver Chrome Extension](https://chrome.google.com/webstore/detail/capsolver/pgojnojmmhpofjgdmaebadhbocahppod), configure API key, enable auto-solving. Use with a persistent browser profile: `BrowserConfig(use_persistent_context=True, user_data_dir="/path/to/profile/with/extension")`.

## Usage

```bash
# CLI shortcuts
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://recaptcha-demo.appspot.com/recaptcha-v2-checkbox.php recaptcha_v2 6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://clifford.io/demo/cloudflare-turnstile turnstile 0x4AAAAAAAGlwMzq_9z6S9Mh
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://nft.porsche.com/onboarding@6 aws_waf
```

### reCAPTCHA v2 (Python)

```python
import capsolver
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig

capsolver.api_key = "CAP-xxxxxxxxxxxxxxxxxxxxx"

solution = capsolver.solve({
    "type": "ReCaptchaV2TaskProxyLess",
    "websiteURL": site_url,
    "websiteKey": site_key,
})
token = solution["gRecaptchaResponse"]

# Inject token and submit
js_code = f"document.getElementById('g-recaptcha-response').value = '{token}'; document.querySelector('button[type=\"submit\"]').click();"
async with AsyncWebCrawler(config=BrowserConfig(headless=False)) as crawler:
    result = await crawler.arun(url=site_url, config=CrawlerRunConfig(js_code=js_code, js_only=True))
```

### Cloudflare Turnstile (Python)

```python
solution = capsolver.solve({
    "type": "AntiTurnstileTaskProxyLess",
    "websiteURL": site_url,
    "websiteKey": site_key,
})
token = solution["token"]
# Inject: document.querySelector('input[name="cf-turnstile-response"]').value = token
```

### Cloudflare Challenge (requires proxy)

```python
solution = capsolver.solve({
    "type": "AntiCloudflareTask",
    "websiteURL": site_url,
    "proxy": "proxy.example.com:8080:username:password",
})
```

## Best Practices

- **Error handling**: Check `solution.get("errorId") == 0`; log `solution.get("errorDescription")` on failure
- **Rate limiting**: Add delays between requests; monitor success rates
- **Cost**: Use package deals for high-volume (up to 60% savings); prefer v2/v3 over Enterprise where sufficient
- **Cloudflare**: Match browser fingerprints, use consistent User-Agent, maintain session cookies
- **Balance**: `capsolver.balance()` — monitor via dashboard

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Invalid API Key | Verify format (`CAP-xxx`) and account status |
| Insufficient Balance | Add funds at dashboard.capsolver.com |
| Site Key Mismatch | Confirm correct site key for target |
| Token Injection Timing | Adjust wait conditions for dynamic content |

```bash
./.agents/scripts/crawl4ai-helper.sh status
curl -X POST https://api.capsolver.com/getBalance \
  -H "Content-Type: application/json" \
  -d '{"clientKey":"CAP-xxxxxxxxxxxxxxxxxxxxx"}'
docker logs crawl4ai --tail 20
```

## Resources

- **CapSolver Docs**: https://docs.capsolver.com/
- **API Reference**: https://docs.capsolver.com/guide/api-how-to-use/
- **Helper Script**: `.agents/scripts/crawl4ai-helper.sh`
- **Config**: `configs/capsolver-config.json`, `configs/capsolver-example.py`
- **MCP Tools**: `configs/mcp-templates/crawl4ai-mcp-config.json`
