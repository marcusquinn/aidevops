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

# browser-use

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: AI-native browser automation that combines vision + DOM for reliable web interaction
- **Install**: `pip install browser-use`
- **Repo**: https://github.com/browser-use/browser-use (50k+ stars, Python, MIT)
- **Docs**: https://docs.browser-use.com/

**When to use**: Complex multi-step web tasks where traditional selectors break. browser-use understands pages visually and semantically, handling dynamic content, popups, and CAPTCHAs better than pure DOM automation.

<!-- AI-CONTEXT-END -->

## Setup

```bash
pip install browser-use
playwright install chromium
```

## Basic Usage

```python
from browser_use import Agent
from langchain_openai import ChatOpenAI

agent = Agent(
    task="Go to reddit.com/r/devops and find the top post this week",
    llm=ChatOpenAI(model="gpt-4o"),
)

result = await agent.run()
print(result)
```

## Key Features

- **Vision + DOM**: Combines screenshot analysis with DOM extraction for robust element identification
- **Multi-tab support**: Navigate across multiple tabs and windows
- **File handling**: Upload and download files
- **Form filling**: Intelligent form detection and completion
- **Error recovery**: Automatic retry with alternative strategies
- **Custom actions**: Register Python functions as browser actions

## Custom Actions

```python
from browser_use import Agent, Controller

controller = Controller()

@controller.action("Extract all prices from the page")
def extract_prices(page):
    prices = page.query_selector_all('[class*="price"]')
    return [p.text_content() for p in prices]

agent = Agent(
    task="Find the cheapest flight from London to New York",
    llm=ChatOpenAI(model="gpt-4o"),
    controller=controller,
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
| Speed | Slower (LLM calls) | Fast | Medium |

## When to Prefer Other Tools

- **Simple, fast automation**: Use Playwright directly
- **Persistent browser sessions**: Use dev-browser
- **Bulk scraping**: Use Crawl4AI
- **Testing your app**: Use Playwright with ARIA snapshots

## Related

- `tools/browser/browser-automation.md` - Browser tool decision tree
- `tools/browser/playwright.md` - Playwright direct automation
- `tools/browser/stagehand.md` - Stagehand AI browser automation
- `tools/browser/skyvern.md` - Computer vision browser automation
