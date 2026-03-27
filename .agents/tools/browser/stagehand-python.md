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

## Setup

```bash
bash .agents/scripts/stagehand-python-helper.sh setup
```

## Python vs JavaScript

| Feature | JavaScript | Python |
|---------|------------|--------|
| Type safety | TypeScript + Zod | Pydantic |
| Async | Native Promises | async/await |
| Data science | Limited | Rich ecosystem |
| Web-first | Native | Good |
| Package mgmt | npm/yarn | pip/uv |

## Basic Usage

```python
import asyncio
from stagehand import StagehandConfig, Stagehand
from pydantic import BaseModel, Field

class PageData(BaseModel):
    title: str = Field(..., description="Page title")
    summary: str = Field(..., description="Page summary")

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
        data = await page.extract("extract the page title and summary", schema=PageData)
        print(f"Title: {data.title}")
    finally:
        await stagehand.close()

asyncio.run(main())
```

## Core Primitives

### Act

```python
await page.act("click the submit button")
await page.act("fill in the email field with user@example.com")
await page.act("select 'Premium' from the subscription dropdown")
```

### Extract

```python
from pydantic import BaseModel, Field
from typing import List

class Product(BaseModel):
    name: str = Field(..., description="Product name")
    price: float = Field(..., description="Price in USD")
    rating: float = Field(..., description="Star rating out of 5")
    in_stock: bool = Field(..., description="Whether item is in stock")

products = await page.extract("extract all product details", schema=List[Product])
```

### Observe

```python
actions = await page.observe()
buttons = await page.observe("find all clickable buttons")
forms = await page.observe("find all form fields")
```

### Agent (autonomous)

```python
agent = stagehand.agent(
    provider="openai",
    model="computer-use-preview",
    integrations=[],
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

STAGEHAND_ENV=LOCAL          # LOCAL or BROWSERBASE
STAGEHAND_HEADLESS=false
STAGEHAND_VERBOSE=1
STAGEHAND_DEBUG_DOM=true

MODEL_NAME=google/gemini-2.5-flash-preview-05-20
MODEL_API_KEY=${GOOGLE_API_KEY}

# Optional cloud browsers
BROWSERBASE_API_KEY=your_browserbase_api_key_here
BROWSERBASE_PROJECT_ID=your_browserbase_project_id_here
```

Advanced config:

```python
config = StagehandConfig(
    env="LOCAL", verbose=1, debug_dom=True, headless=False,
    model_name="google/gemini-2.5-flash-preview-05-20",
    model_api_key=os.getenv("GOOGLE_API_KEY"),
    browser_options={"args": ["--disable-web-security"]}
)
```

## Examples

### E-commerce

```python
async def search_products(query: str) -> List[Product]:
    config = StagehandConfig(env="LOCAL", headless=True)
    stagehand = Stagehand(config)
    try:
        await stagehand.init()
        page = stagehand.page
        await page.goto("https://amazon.com")
        await page.act(f'search for "{query}"')
        return await page.extract("extract the first 5 products", schema=List[Product])
    finally:
        await stagehand.close()
```

### Data Collection with Error Handling

```python
from pydantic import BaseModel, Field, ValidationError
from typing import Optional

class Article(BaseModel):
    headline: str = Field(..., description="Article headline")
    summary: str = Field(..., description="Article summary")
    author: Optional[str] = Field(None, description="Article author")

async def scrape_news(url: str) -> List[Article]:
    stagehand = Stagehand(StagehandConfig(env="LOCAL", headless=True, verbose=1))
    try:
        await stagehand.init()
        page = stagehand.page
        await page.goto(url)
        try:
            await page.act("accept cookies if there's a banner")
        except Exception:
            pass
        return await page.extract("extract all news articles", schema=List[Article])
    except ValidationError as e:
        print(f"Validation error: {e}")
        return []
    finally:
        await stagehand.close()
```

## MCP Integration

```bash
bash .agents/scripts/setup-mcp-integrations.sh stagehand-python
```

```python
agent = stagehand.agent(
    provider="openai",
    model="computer-use-preview",
    integrations=[],  # MCP integrations added here
    system_prompt="You have access to browser automation and external tools."
)
await agent.execute("Search for information and save it to the database")
```

## Use Cases

| Domain | Examples |
|--------|---------|
| E-commerce | Price comparison, purchase workflows, inventory monitoring |
| Data collection | Web scraping, competitive analysis, content aggregation |
| Testing & QA | User journey testing, form validation, accessibility reporting |
| Business automation | Lead generation, CRM data entry, report generation |

## Helper Commands

```bash
bash .agents/scripts/stagehand-python-helper.sh install    # Install
bash .agents/scripts/stagehand-python-helper.sh setup      # Complete setup
bash .agents/scripts/stagehand-python-helper.sh status     # Check installation
bash .agents/scripts/stagehand-python-helper.sh activate   # Show activation command
bash .agents/scripts/stagehand-python-helper.sh clean      # Clean cache/logs
source ~/.aidevops/stagehand-python/.venv/bin/activate     # Activate venv
python examples/basic_example.py                           # Run basic example
```

## Resources

- Stagehand Python docs: https://docs.stagehand.dev
- GitHub: https://github.com/browserbase/stagehand-python
- Pydantic: https://docs.pydantic.dev
- JavaScript version: `.agents/tools/browser/stagehand.md`
- MCP integrations: `.agents/aidevops/mcp-integrations.md`
