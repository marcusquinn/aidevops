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
- **Repo**: https://github.com/browser-use/browser-use (102k+ stars, Python, MIT)
- **Docs**: https://docs.browser-use.com/
- **Cloud**: https://cloud.browser-use.com/ (managed stealth browsers, CAPTCHA handling)
- **Version**: 0.13.x package; Browser Use CLI 3.0 (July 2026)

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
import asyncio

from browser_use import Agent, BrowserProfile, ChatBrowserUse

async def main():
    agent = Agent(
        task="Find the number of stars of the browser-use repo",
        llm=ChatBrowserUse(model="openai/gpt-5.5"),
        # llm=ChatBrowserUse(model="bu-2-0"),  # Browser Use's optimized model
        browser_profile=BrowserProfile(
            headless=False,
            allowed_domains=["*.github.com"],
        ),
    )
    history = await agent.run()
    print(history.final_result())

if __name__ == "__main__":
    asyncio.run(main())
```

**Alternative LLM providers:**

```python
from browser_use import Agent, ChatAnthropic, ChatBrowserUse, ChatGoogle

# Browser Use API key can route provider-prefixed model IDs.
agent = Agent(task="...", llm=ChatBrowserUse(model="anthropic/claude-sonnet-4-6"))

# Google Gemini
agent = Agent(task="...", llm=ChatGoogle(model="gemini-3-flash-preview"))

# Anthropic Claude
agent = Agent(task="...", llm=ChatAnthropic(model="claude-sonnet-4-6"))
```

## CLI 3.0

Browser Use CLI 3.0 is powered by Browser Harness and gives coding agents a
direct Python command surface while the CLI manages the browser in the
background:

```bash
browser-use <<'PY'
new_tab("https://example.com")
print(page_info())
PY
```

Use `browser-use skill` to print/install the packaged agent skill for Claude
Code, Codex, Cursor, Gemini, OpenCode, and similar coding-agent skill
directories.

## Templates

```bash
uvx browser-use init --template default    # Minimal setup
uvx browser-use init --template advanced   # All config options with comments
uvx browser-use init --template tools      # Custom tools examples
uvx browser-use init --template default --output my_agent.py  # Custom path
```

## Custom Tools

```python
from browser_use import Agent, BrowserProfile, ChatBrowserUse, Tools

tools = Tools()

@tools.action(description="Description of what this tool does.")
def custom_tool(param: str) -> str:
    return f"Result: {param}"

agent = Agent(
    task="Your task",
    llm=ChatBrowserUse(),
    browser_profile=BrowserProfile(headless=False),
    tools=tools,
)
```

## Cloud and Hosted Agent

```python
from browser_use import Agent, Browser, ChatBrowserUse

browser = Browser(use_cloud=True)  # Requires BROWSER_USE_API_KEY

agent = Agent(
    task="Fill in this job application",
    llm=ChatBrowserUse(),
    browser=browser,
)
```

Use Browser Use Cloud when you need managed browser infrastructure, proxy
rotation, stealth, CAPTCHA handling, parallel execution, persistent filesystem,
or hosted-agent integrations. Use the open-source agent when you need custom
tools, code-level integration, or self-hosting.

## Authentication

```python
from browser_use import Agent, Browser, ChatGoogle

# Reuse existing Chrome profile (preserves logins)
profile = Browser.list_chrome_profiles()[0]["directory"]
browser = Browser.from_system_chrome(profile_directory=profile)

agent = Agent(
    task="Search with an existing logged-in browser profile",
    llm=ChatGoogle(model="gemini-3-flash-preview"),
    browser=browser,
)
```

For remote profile sync, prefer documented Browser Use Cloud profile tooling and
store API keys with `aidevops secret` or `~/.config/aidevops/credentials.sh`.

## Comparison with Other Tools

| Feature | browser-use | Playwright | Stagehand |
|---------|-------------|------------|-----------|
| AI-native | Yes | No | Yes |
| Vision understanding | Yes | Screenshot only | Yes |
| DOM extraction | Yes | Yes | Yes |
| Multi-step planning | Yes | Manual | Limited |
| Error recovery | Automatic | Manual | Limited |
| Custom tools | Yes (`Tools`) | N/A | No |
| Agent skill install | Yes (`browser-use skill`) | No | No |
| CLI/control loop | CLI 3.0 + Browser Harness | Playwright API/CLI | SDK/API |
| Cloud/stealth | Cloud agent, proxies, CAPTCHA | No | Browserbase |
| Speed | Faster with `ChatBrowserUse`; slower than deterministic scripts | Fastest for known flows | Medium |
| Benchmarking | Upstream 100-task BU Bench | Local deterministic benchmarks | Local deterministic benchmarks |
| Own model | Yes (`ChatBrowserUse`, `bu-*`) | N/A | No |

## When to Prefer Other Tools

- **Simple, fast automation**: Use Playwright directly
- **Persistent browser sessions**: Use dev-browser
- **Bulk scraping**: Use Crawl4AI
- **Testing your app**: Use Playwright with ARIA snapshots
- **Natural language selectors in JS/Browserbase stacks**: Use Stagehand
- **Vision-only/canvas-heavy or CAPTCHA-heavy tasks**: Use Skyvern or Browser Use Cloud

## Related

- `tools/browser/browser-automation.md` - Browser tool decision tree
- `tools/browser/playwright.md` - Playwright direct automation
- `tools/browser/stagehand.md` - Stagehand AI browser automation
- `tools/browser/skyvern.md` - Computer vision browser automation
