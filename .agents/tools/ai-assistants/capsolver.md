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

- CapSolver: Automated CAPTCHA solving service (99.9% accuracy, <10s)
- Setup: `./.agents/scripts/crawl4ai-helper.sh capsolver-setup`
- API key: `export CAPSOLVER_API_KEY="CAP-xxxxx"` from dashboard.capsolver.com
- Crawl command: `./.agents/scripts/crawl4ai-helper.sh captcha-crawl URL captcha_type site_key`
- CAPTCHA types:
  - reCAPTCHA v2/v3: $0.5/1000 req, <9s/<3s
  - reCAPTCHA Enterprise: $1-3/1000 req
  - Cloudflare Turnstile: $3/1000 req, <3s
  - AWS WAF, GeeTest: Contact/0.5 per 1000
  - Image OCR: $0.4/1000 req, <1s
- Python: `import capsolver; capsolver.api_key = "KEY"; solution = capsolver.solve({...})`
- Best practices: Respect rate limits, use delays, monitor balance
- Config: `configs/capsolver-config.json`, `configs/capsolver-example.py`
<!-- AI-CONTEXT-END -->

## Overview

CapSolver is the world's leading automated CAPTCHA solving service that integrates seamlessly with Crawl4AI to provide uninterrupted web crawling and data extraction. This partnership enables developers to bypass CAPTCHAs and anti-bot measures automatically.

### Key Benefits

- **🤖 Automated CAPTCHA Handling**: Eliminate manual intervention for CAPTCHA solving
- **⚡ High Success Rate**: 99.9% accuracy with fast response times (< 10 seconds)
- **💰 Cost-Effective**: Starting from $0.4/1000 requests with package discounts up to 60%
- **🛡️ Anti-Bot Bypass**: Handle complex anti-bot mechanisms seamlessly
- **🔧 Easy Integration**: Both API and browser extension methods available

## 🎯 Supported CAPTCHA Types

### **reCAPTCHA Family**

- **reCAPTCHA v2**: Checkbox "I'm not a robot" - $0.5/1000 requests, < 9s
- **reCAPTCHA v3**: Invisible scoring system - $0.5/1000 requests, < 3s  
- **reCAPTCHA v2 Enterprise**: Enterprise version - $1/1000 requests, < 9s
- **reCAPTCHA v3 Enterprise**: Enterprise with ≥0.9 score - $3/1000 requests, < 3s

### **Cloudflare Protection**

- **Cloudflare Turnstile**: Modern CAPTCHA alternative - $3/1000 requests, < 3s
- **Cloudflare Challenge**: 5-second shield bypass - Contact for pricing, < 10s

### **Other Popular Types**

- **AWS WAF**: Web Application Firewall - Contact for pricing, < 5s
- **GeeTest v3/v4**: Popular in Asia - $0.5/1000 requests, < 5s
- **Image-to-Text OCR**: Traditional image CAPTCHAs - $0.4/1000 requests, < 1s

## 🛠️ Integration Methods

### **1. API Integration (Recommended)**

**Advantages**: More flexible, precise control, better error handling

```bash
# Setup CapSolver integration
./.agents/scripts/crawl4ai-helper.sh capsolver-setup

# Set API key
export CAPSOLVER_API_KEY="CAP-xxxxxxxxxxxxxxxxxxxxx"

# Crawl with CAPTCHA solving
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://example.com recaptcha_v2 6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9
```

### **2. Browser Extension Integration**

**Advantages**: Easy setup, automatic detection, no coding required

1. Install extension: [CapSolver Chrome Extension](https://chrome.google.com/webstore/detail/capsolver/pgojnojmmhpofjgdmaebadhbocahppod)
2. Configure API key in extension settings
3. Enable automatic solving mode
4. Run Crawl4AI with extension-enabled browser profile

## 🔧 Quick Start Guide

### **Step 1: Get CapSolver API Key**

1. Visit [CapSolver Dashboard](https://dashboard.capsolver.com/dashboard/overview)
2. Sign up for an account
3. Get your API key (format: `CAP-xxxxxxxxxxxxxxxxxxxxx`)
4. Add funds to your account for CAPTCHA solving

### **Step 2: Setup Integration**

```bash
# Install Crawl4AI with CapSolver support
./.agents/scripts/crawl4ai-helper.sh install
./.agents/scripts/crawl4ai-helper.sh docker-setup
./.agents/scripts/crawl4ai-helper.sh capsolver-setup

# Set your API key
export CAPSOLVER_API_KEY="CAP-xxxxxxxxxxxxxxxxxxxxx"
```

### **Step 3: Start Crawling with CAPTCHA Solving**

```bash
# Basic CAPTCHA crawling
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://recaptcha-demo.appspot.com/recaptcha-v2-checkbox.php recaptcha_v2 6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9

# Cloudflare Turnstile
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://clifford.io/demo/cloudflare-turnstile turnstile 0x4AAAAAAAGlwMzq_9z6S9Mh

# AWS WAF bypass
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://nft.porsche.com/onboarding@6 aws_waf
```

## 📊 Usage Examples

### **reCAPTCHA v2 Solving**

```python
import asyncio
import capsolver
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig, CacheMode

capsolver.api_key = "CAP-xxxxxxxxxxxxxxxxxxxxx"

async def solve_recaptcha_v2():
    site_url = "https://recaptcha-demo.appspot.com/recaptcha-v2-checkbox.php"
    site_key = "6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9"
    
    # Solve CAPTCHA
    solution = capsolver.solve({
        "type": "ReCaptchaV2TaskProxyLess",
        "websiteURL": site_url,
        "websiteKey": site_key,
    })
    token = solution["gRecaptchaResponse"]
    
    # Inject token and continue crawling
    browser_config = BrowserConfig(verbose=True, headless=False)
    async with AsyncWebCrawler(config=browser_config) as crawler:
        js_code = f"""
            document.getElementById('g-recaptcha-response').value = '{token}';
            document.querySelector('button[type="submit"]').click();
        """
        
        config = CrawlerRunConfig(js_code=js_code, js_only=True)
        result = await crawler.arun(url=site_url, config=config)
        return result.markdown
```

### **Cloudflare Turnstile Solving**

```python
async def solve_turnstile():
    site_url = "https://clifford.io/demo/cloudflare-turnstile"
    site_key = "0x4AAAAAAAGlwMzq_9z6S9Mh"
    
    # Solve Turnstile
    solution = capsolver.solve({
        "type": "AntiTurnstileTaskProxyLess",
        "websiteURL": site_url,
        "websiteKey": site_key,
    })
    token = solution["token"]
    
    # Inject token
    js_code = f"""
        document.querySelector('input[name="cf-turnstile-response"]').value = '{token}';
        document.querySelector('button[type="submit"]').click();
    """
    
    # Continue with crawling...
```

## 🔍 Advanced Features

### **Automatic CAPTCHA Detection**

CapSolver can automatically detect and solve CAPTCHAs without manual configuration:

```python
# Enable automatic detection
browser_config = BrowserConfig(
    use_persistent_context=True,
    user_data_dir="/path/to/profile/with/extension"
)
```

### **Proxy Support for Cloudflare**

For Cloudflare challenges, proxy support is required:

```python
solution = capsolver.solve({
    "type": "AntiCloudflareTask",
    "websiteURL": site_url,
    "proxy": "proxy.example.com:8080:username:password",
})
```

### **Balance Monitoring**

```python
# Check account balance
balance = capsolver.balance()
print(f"Remaining balance: ${balance}")
```

## 💡 Best Practices

### **1. Error Handling**

```python
try:
    solution = capsolver.solve(task_config)
    if solution.get("errorId") == 0:
        token = solution["solution"]["gRecaptchaResponse"]
    else:
        print(f"CAPTCHA solving failed: {solution.get('errorDescription')}")
except Exception as e:
    print(f"Error: {e}")
```

### **2. Rate Limiting**

- Respect website rate limits even with CAPTCHA solving
- Use delays between requests to avoid triggering additional anti-bot measures
- Monitor success rates and adjust strategies accordingly

### **3. Cost Optimization**

- Use package deals for high-volume operations (up to 60% savings)
- Monitor balance and usage through CapSolver dashboard
- Choose appropriate CAPTCHA types (v2 vs v3 vs Enterprise)

### **4. Success Rate Optimization**

- Ensure browser fingerprints match for Cloudflare challenges
- Use consistent User-Agent strings
- Maintain session cookies when possible

## 🔧 Troubleshooting

### **Common Issues**

1. **Invalid API Key**: Verify key format and account status
2. **Insufficient Balance**: Add funds to CapSolver account
3. **Site Key Mismatch**: Ensure correct site key for target website
4. **Token Injection Timing**: Adjust wait conditions for dynamic content

### **Debug Commands**

```bash
# Check CapSolver integration status
./.agents/scripts/crawl4ai-helper.sh status

# Test API key
curl -X POST https://api.capsolver.com/getBalance \
  -H "Content-Type: application/json" \
  -d '{"clientKey":"CAP-xxxxxxxxxxxxxxxxxxxxx"}'

# Verify Crawl4AI Docker status
docker logs crawl4ai --tail 20
```

## 📚 Resources

### **Official Documentation**

- **CapSolver Docs**: https://docs.capsolver.com/
- **Crawl4AI Partnership**: https://www.capsolver.com/blog/Partners/crawl4ai-capsolver/
- **API Reference**: https://docs.capsolver.com/guide/api-how-to-use/

### **Framework Integration**

- **Helper Script**: `.agents/scripts/crawl4ai-helper.sh`
- **Configuration**: `configs/capsolver-config.json`
- **Examples**: `configs/capsolver-example.py`
- **MCP Tools**: `configs/mcp-templates/crawl4ai-mcp-config.json`

### **Support Channels**

- **CapSolver Support**: https://dashboard.capsolver.com/
- **Discord Community**: Available through CapSolver dashboard
- **Framework Issues**: GitHub repository issues

## 🎯 Use Cases

### **E-commerce Data Collection**

- Product information scraping with anti-bot bypass
- Price monitoring across protected sites
- Inventory tracking with CAPTCHA handling

### **Market Research**

- News aggregation from protected sources
- Social media data collection
- Competitor analysis with stealth crawling

### **Academic Research**

- Large-scale data collection for research
- Academic paper aggregation
- Citation network analysis

### **SEO & Marketing**

- Content analysis across protected sites
- Backlink research with CAPTCHA bypass
- SERP data collection

The CapSolver + Crawl4AI integration provides enterprise-grade CAPTCHA solving capabilities, enabling uninterrupted web crawling and data extraction for any use case.
