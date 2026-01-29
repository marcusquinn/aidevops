---
description: Troubleshooting guide for common issues
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# Troubleshooting Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

**Before reporting a bug**: Check service status page first.

**Service Status Pages**:
- GitHub: https://www.githubstatus.com/
- GitLab: https://status.gitlab.com/
- Cloudflare: https://www.cloudflarestatus.com/
- Hetzner: https://status.hetzner.com/
- Hostinger: https://status.hostinger.com/
- SonarCloud: https://sonarcloudstatus.io/
- Codacy: https://status.codacy.com/
- Snyk: https://status.snyk.io/

**MCP Issues**:
- Chrome DevTools: Install Chrome Canary, fix permissions
- Playwright: Install browsers (`bunx playwright install`)
- API Auth: Verify keys with curl, check env vars
- Debug: `DEBUG=chrome-devtools-mcp bunx chrome-devtools-mcp@latest`
- Diagnostics: `bash .agent/scripts/collect-mcp-diagnostics.sh`

**Retry Strategy**: Use exponential backoff for transient failures
<!-- AI-CONTEXT-END -->

## Common Issues & Solutions

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

#### **Issue: Ahrefs MCP "connection closed" error**

This is a common issue with multiple potential causes:

**Cause 1: Wrong API key type**

```bash
# JWT-style tokens (long, with dots) do NOT work
# Use standard 40-character API key from https://ahrefs.com/api

# Verify your key format - should be ~40 alphanumeric characters
echo $AHREFS_API_KEY | wc -c  # Should be around 40-45
```

**Cause 2: Wrong environment variable name**

```bash
# The @ahrefs/mcp package expects API_KEY, not AHREFS_API_KEY
# Store as AHREFS_API_KEY in your env, but pass as API_KEY to the MCP
```

**Cause 3: OpenCode environment blocks don't expand variables**

```bash
# This does NOT work in OpenCode - treats ${AHREFS_API_KEY} as literal string:
# "env": { "API_KEY": "${AHREFS_API_KEY}" }

# Solution: Use bash wrapper pattern to expand at runtime:
# "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY npx -y @ahrefs/mcp@latest"]
```

**Working OpenCode configuration:**

```json
{
  "ahrefs": {
    "type": "local",
    "command": [
      "/bin/bash",
      "-c",
      "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"
    ],
    "enabled": true
  }
}
```

**Verify API key works:**

```bash
# Test the API directly
curl -H "Authorization: Bearer $AHREFS_API_KEY" https://apiv2.ahrefs.com/v2/subscription_info

# Should return JSON with subscription info, not an error
```

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

## Debugging Steps

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

### **5. Test Configuration Changes with CLI**

The OpenCode TUI requires restart to pick up `opencode.json` changes. Use CLI for quick testing:

```bash
# Test new MCP configuration
opencode run "List available tools from dataforseo_*" --agent SEO

# Debug MCP connection (shows errors in terminal)
opencode run "Call serper_google_search with query 'test'" --agent SEO 2>&1

# Verify agent has correct tool access
opencode run "What MCP tools can you access?" --agent SEO

# Test slash commands
opencode run "/new-command arg1" --agent Build+
```

**Workflow for adding new MCPs:**

1. Edit `~/.config/opencode/opencode.json`
2. Test with CLI: `opencode run "Test [mcp]" --agent [agent] 2>&1`
3. If working, restart TUI to use interactively
4. If failing, check stderr output and iterate on config
5. Update `generate-opencode-agents.sh` to persist changes

**Helper script for common tests:**

```bash
~/.aidevops/agents/scripts/opencode-test-helper.sh test-mcp dataforseo SEO
~/.aidevops/agents/scripts/opencode-test-helper.sh test-agent Build+
```

## Performance Optimization

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

## Monitoring & Logging

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

## Recovery Procedures

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

## Getting Help

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
