# 🔧 MCP Integrations Troubleshooting Guide

## 🚨 **Common Issues & Solutions**

### **Chrome DevTools MCP Issues**

#### **Issue: Chrome not launching**

```bash
# Solution: Install Chrome Canary
brew install --cask google-chrome-canary

# Or use stable Chrome
npx chrome-devtools-mcp@latest --channel=stable
```

#### **Issue: Permission denied errors**

```bash
# Solution: Fix permissions
sudo chown -R $(whoami) ~/.cache/puppeteer
chmod +x ~/.cache/puppeteer/*/chrome-*/chrome
```

#### **Issue: Headless mode not working**

```bash
# Solution: Enable headless mode explicitly
npx chrome-devtools-mcp@latest --headless=true --no-sandbox
```

### **Playwright MCP Issues**

#### **Issue: Browsers not installed**

```bash
# Solution: Install all browsers
npx playwright install

# Install specific browser
npx playwright install chromium
```

#### **Issue: Browser launch timeout**

```bash
# Solution: Increase timeout and disable sandbox
npx playwright-mcp@latest --timeout=60000 --no-sandbox
```

#### **Issue: WebKit not working on Linux**

```bash
# Solution: Install WebKit dependencies
sudo apt-get install libwoff1 libopus0 libwebp6 libwebpdemux2 libenchant1c2a libgudev-1.0-0 libsecret-1-0 libhyphen0 libgdk-pixbuf2.0-0 libegl1 libnotify4 libxss1 libasound2
```

### **API-Based MCP Issues**

#### **Issue: Ahrefs API authentication failed**

```bash
# Solution: Verify API key
export AHREFS_API_KEY="your_actual_api_key"
curl -H "Authorization: Bearer $AHREFS_API_KEY" https://apiv2.ahrefs.com/v2/subscription_info
```

#### **Issue: Perplexity API rate limiting**

```bash
# Solution: Implement rate limiting
export PERPLEXITY_RATE_LIMIT="10" # requests per minute
```

#### **Issue: Cloudflare API errors**

```bash
# Solution: Verify credentials
export CLOUDFLARE_ACCOUNT_ID="your_account_id"
export CLOUDFLARE_API_TOKEN="your_api_token"
curl -X GET "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
```

## 🔍 **Debugging Steps**

### **1. Check MCP Server Status**

```bash
# Test if MCP server is responding
npx chrome-devtools-mcp@latest --test-connection

# Check server logs
tail -f /tmp/chrome-mcp.log
```

### **2. Validate Configuration**

```bash
# Validate JSON configuration
python -m json.tool configs/mcp-templates/complete-mcp-config.json

# Test individual MCP
npx chrome-devtools-mcp@latest --config-test
```

### **3. Network Connectivity**

```bash
# Test network access
curl -I https://api.ahrefs.com
curl -I https://api.perplexity.ai
curl -I https://api.cloudflare.com
```

### **4. Environment Variables**

```bash
# Check environment variables
echo $AHREFS_API_KEY
echo $PERPLEXITY_API_KEY
echo $CLOUDFLARE_ACCOUNT_ID
echo $CLOUDFLARE_API_TOKEN
```

## 🛠️ **Performance Optimization**

### **Chrome DevTools Optimization**

```json
{
  "chrome-devtools": {
    "args": [
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      "--disable-renderer-backgrounding"
    ]
  }
}
```

### **Playwright Optimization**

```json
{
  "playwright": {
    "args": [
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--no-first-run",
      "--no-default-browser-check"
    ]
  }
}
```

## 📊 **Monitoring & Logging**

### **Enable Debug Logging**

```bash
# Chrome DevTools debug
DEBUG=chrome-devtools-mcp npx chrome-devtools-mcp@latest

# Playwright debug
DEBUG=pw:api npx playwright-mcp@latest
```

### **Log File Locations**

```text
Chrome DevTools: /tmp/chrome-mcp.log
Playwright: /tmp/playwright-mcp.log
API MCPs: ~/.mcp/logs/
```

### **Health Check Script**

```bash
#!/bin/bash
# MCP Health Check
echo "🔍 Checking MCP integrations..."

# Test Chrome DevTools
if npx chrome-devtools-mcp@latest --health-check; then
  echo "✅ Chrome DevTools MCP: OK"
else
  echo "❌ Chrome DevTools MCP: FAILED"
fi

# Test Playwright
if npx playwright-mcp@latest --health-check; then
  echo "✅ Playwright MCP: OK"
else
  echo "❌ Playwright MCP: FAILED"
fi

# Test API connections
if curl -s https://api.ahrefs.com > /dev/null; then
  echo "✅ Ahrefs API: Reachable"
else
  echo "❌ Ahrefs API: Unreachable"
fi
```

## 🔄 **Recovery Procedures**

### **Reset MCP Configuration**

```bash
# Backup current config
cp ~/.config/mcp/config.json ~/.config/mcp/config.json.backup

# Reset to defaults
rm ~/.config/mcp/config.json
bash .agent/scripts/setup-mcp-integrations.sh all
```

### **Clear Cache and Restart**

```bash
# Clear browser cache
rm -rf ~/.cache/puppeteer
rm -rf ~/.cache/playwright

# Reinstall browsers
npx playwright install --force
```

### **Emergency Fallback**

```bash
# Use basic configuration without advanced features
npx chrome-devtools-mcp@latest --safe-mode
npx playwright-mcp@latest --basic-mode
```

## 📞 **Getting Help**

### **Log Collection for Support**

```bash
# Collect diagnostic information
bash .agent/scripts/collect-mcp-diagnostics.sh

# This creates: mcp-diagnostics-$(date +%Y%m%d).tar.gz
```

### **Community Resources**

- [MCP GitHub Discussions](https://github.com/modelcontextprotocol/discussions)
- [Chrome DevTools MCP Issues](https://github.com/chromedevtools/chrome-devtools-mcp/issues)
- [Playwright Community](https://playwright.dev/community)

### **Professional Support**

- Ahrefs API Support: [support@ahrefs.com](mailto:support@ahrefs.com)
- Cloudflare Support: [Cloudflare Support Portal](https://support.cloudflare.com/)
- Perplexity API: [Perplexity Documentation](https://docs.perplexity.ai/)
