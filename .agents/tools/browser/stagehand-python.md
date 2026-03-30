---
description: Stagehand Python SDK for browser automation
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

# Stagehand Python AI Browser Automation

<!-- AI-CONTEXT-START -->

## Quick Reference

| Item | Value |
|------|-------|
| Helper | `bash .agents/scripts/stagehand-python-helper.sh setup\|install\|status\|activate\|clean` |
| Virtual env | `~/.aidevops/stagehand-python/.venv/` |
| Config | `~/.aidevops/stagehand-python/.env` |
| Default model | `google/gemini-2.5-flash-preview-05-20` |
| API key vars | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY` |

**Core primitives:**

- `page.act("natural language action")` — click, fill, scroll
- `page.extract("instruction", schema=PydanticModel)` — structured data
- `page.observe()` — discover available actions
- `stagehand.agent()` — autonomous workflows

<!-- AI-CONTEXT-END -->

## Usage

```python
import asyncio
from stagehand import StagehandConfig, Stagehand
from pydantic import BaseModel, Field
from typing import List

class PageData(BaseModel):
    title: str = Field(..., description="Page title")

async def main():
    config = StagehandConfig(
        env="LOCAL",
        model_name="google/gemini-2.5-flash-preview-05-20",
        model_api_key="your_api_key",
        headless=False
    )
    stagehand = Stagehand(config)
    try:
        await stagehand.init()
        page = stagehand.page
        await page.goto("https://example.com")
        await page.act("scroll down to see more content")
        data = await page.extract("extract the page title", schema=PageData)
        print(f"Title: {data.title}")
    finally:
        await stagehand.close()

asyncio.run(main())
```

### Act / Observe

```python
await page.act("click the submit button")
actions = await page.observe()                    # all available actions
buttons = await page.observe("find all buttons")  # filtered
```

### Extract

```python
class Product(BaseModel):
    name: str = Field(..., description="Product name")
    price: float = Field(..., description="Price in USD")

products = await page.extract("extract all product details", schema=List[Product])
```

### Agent (autonomous)

```python
agent = stagehand.agent(
    provider="openai", model="computer-use-preview",
    system_prompt="You are a helpful browser automation agent."
)
await agent.execute("complete the checkout process for 2 items")
```

## Configuration

`~/.aidevops/stagehand-python/.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_api_key_here
GOOGLE_API_KEY=your_google_api_key_here
STAGEHAND_ENV=LOCAL                               # LOCAL or BROWSERBASE
STAGEHAND_HEADLESS=false
STAGEHAND_VERBOSE=1
STAGEHAND_DEBUG_DOM=true
MODEL_NAME=google/gemini-2.5-flash-preview-05-20
MODEL_API_KEY=${GOOGLE_API_KEY}
BROWSERBASE_API_KEY=your_browserbase_api_key_here  # optional cloud browsers
BROWSERBASE_PROJECT_ID=your_browserbase_project_id_here
```

## MCP Integration

```bash
bash .agents/scripts/setup-mcp-integrations.sh stagehand-python
```

## Resources

- Stagehand Python docs: https://docs.stagehand.dev
- GitHub: https://github.com/browserbase/stagehand-python
- Pydantic: https://docs.pydantic.dev
- JavaScript version: `.agents/tools/browser/stagehand.md`
- MCP integrations: `.agents/aidevops/mcp-integrations.md`
