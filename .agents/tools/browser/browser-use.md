---
description: browser-use - AI-native browser automation with vision and DOM understanding
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# browser-use

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: AI-native browser automation that combines vision + DOM for reliable web interaction
- **Install**: `uv add browser-use` (Python >= 3.11, [uv](https://docs.astral.sh/uv/) recommended)
- **Repo**: https://github.com/browser-use/browser-use (80k+ stars, Python, MIT)
- **Docs**: https://docs.browser-use.com/
- **Cloud**: https://cloud.browser-use.com/ (managed stealth browsers, CAPTCHA handling)
- **Version**: 0.12.x (March 2026)

**When to use**: Complex multi-step web tasks where traditional selectors break. browser-use understands pages visually and semantically, handling dynamic content, popups, and CAPTCHAs better than pure DOM automation.

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Recommended (uv)
uv init && uv add browser-use && uv sync

# Install Chromium if not present
uvx browser-use install

# Alternative (pip)
pip install browser-use
playwright install chromium
```

**LLM provider setup** (pick one):

```bash
# .env
BROWSER_USE_API_KEY=your-key        # Browser Use Cloud (optimised for browser tasks)
# GOOGLE_API_KEY=your-key            # Google Gemini
# ANTHROPIC_API_KEY=your-key         # Anthropic Claude
# OPENAI_API_KEY=your-key            # OpenAI
```

## Basic Usage

```python
from browser_use import Agent, Browser, ChatBrowserUse
import asyncio

async def main():
    agent = Agent(
        task="Find the number of stars of the browser-use repo",
        llm=ChatBrowserUse(),  # Optimised for browser automation
        browser=Browser(),
    )
    await agent.run()

if __name__ == "__main__":
    asyncio.run(main())
```

**Alternative LLM providers:**

```python
from browser_use import ChatGoogle, ChatAnthropic

# Google Gemini
agent = Agent(task="...", llm=ChatGoogle(model="gemini-3-flash-preview"))

# Anthropic Claude
agent = Agent(task="...", llm=ChatAnthropic(model="claude-sonnet-4-6"))
```

## CLI

Persistent browser session from the command line:

```bash
browser-use open https://example.com    # Navigate to URL
browser-use state                       # See clickable elements
browser-use click 5                     # Click element by index
browser-use type "Hello"                # Type text
browser-use screenshot page.png         # Take screenshot
browser-use close                       # Close browser
```

## Templates

```bash
uvx browser-use init --template default    # Minimal setup
uvx browser-use init --template advanced   # All config options with comments
uvx browser-use init --template tools      # Custom tools examples
uvx browser-use init --template default --output my_agent.py  # Custom path
```

## Custom Tools

```python
from browser_use import Agent, Browser, Tools, ChatBrowserUse

tools = Tools()

@tools.action(description="Description of what this tool does.")
def custom_tool(param: str) -> str:
    return f"Result: {param}"

agent = Agent(
    task="Your task",
    llm=ChatBrowserUse(),
    browser=Browser(),
    tools=tools,
)
```

## Cloud Mode

```python
from browser_use import Agent, Browser, ChatBrowserUse

browser = Browser(use_cloud=True)  # Requires BROWSER_USE_API_KEY

agent = Agent(
    task="Fill in this job application",
    llm=ChatBrowserUse(),
    browser=browser,
)
```

## Authentication

```python
from browser_use import Browser, BrowserConfig

# Reuse existing Chrome profile (preserves logins)
browser = Browser(
    config=BrowserConfig(
        chrome_instance_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    )
)
```

## Comparison with Other Tools

| Feature | browser-use | Playwright | Stagehand |
|---------|-------------|------------|-----------|
| AI-native | Yes | No | Yes |
| Vision understanding | Yes | Screenshot only | Yes |
| DOM extraction | Yes | Yes | Yes |
| Multi-step planning | Yes | Manual | Limited |
| Error recovery | Automatic | Manual | Limited |
| Custom tools | Yes (`Tools`) | N/A | No |
| CLI | Yes | Yes (playwright-cli) | No |
| Cloud/stealth | Yes (Browser Use Cloud) | No | Yes (Browserbase) |
| Speed | Slower (LLM calls) | Fast | Medium |
| Own model | Yes (`ChatBrowserUse`) | N/A | No |

## When to Prefer Other Tools

- **Simple, fast automation**: Use Playwright directly
- **Persistent browser sessions**: Use dev-browser
- **Bulk scraping**: Use Crawl4AI
- **Testing your app**: Use Playwright with ARIA snapshots
- **Natural language on unknown pages**: Use Stagehand

## Related

- `tools/browser/browser-automation.md` - Browser tool decision tree
- `tools/browser/playwright.md` - Playwright direct automation
- `tools/browser/stagehand.md` - Stagehand AI browser automation
- `tools/browser/skyvern.md` - Computer vision browser automation
