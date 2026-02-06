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

# Stagehand Python AI Browser Automation Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- Stagehand Python: AI-powered browser automation with Pydantic validation
- Helper: `bash .agent/scripts/stagehand-python-helper.sh setup|install|status|activate|clean`
- Virtual env: `~/.aidevops/stagehand-python/.venv/`
- Config: `~/.aidevops/stagehand-python/.env`
- Core primitives:
  - `page.act("natural language action")` - Click, fill, scroll
  - `page.extract("instruction", schema=PydanticModel)` - Structured data
  - `page.observe()` - Discover available actions
  - `stagehand.agent()` - Autonomous workflows
- Models: `google/gemini-2.5-flash-preview-05-20`, OpenAI, Anthropic
- API keys: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`
- Env vars: `STAGEHAND_ENV=LOCAL`, `STAGEHAND_HEADLESS=false`
- Use cases: E-commerce, data collection, testing, business automation
<!-- AI-CONTEXT-END -->

**AI-powered browser automation with natural language control - Now available in Python with Pydantic schema validation**

## Overview

Stagehand Python brings the power of AI-driven browser automation to Python developers with native async/await support, Pydantic schema validation, and seamless integration with the Python ecosystem.

### **🌟 Key Features**

- **🧠 AI-Powered Actions**: Use natural language to interact with web pages
- **📊 Pydantic Schema Validation**: Type-safe structured data extraction
- **🔍 Intelligent Observation**: Discover available actions on any page
- **🤖 Autonomous Agents**: Automate entire workflows with AI decision-making
- **🔒 Local-First**: Works with local browsers for complete privacy
- **⚡ Async/Await Support**: Native Python async programming patterns

### **🆚 Python vs JavaScript Comparison**

| Feature | JavaScript | Python | Best For |
|---------|------------|--------|----------|
| **Type Safety** | TypeScript + Zod | ✅ Pydantic | Python: Better type hints |
| **Async Support** | Native Promises | ✅ async/await | Python: More intuitive |
| **Data Science** | Limited | ✅ Rich ecosystem | Python: ML/AI workflows |
| **Web Development** | ✅ Native | Good | JavaScript: Web-first |
| **Package Management** | npm/yarn | ✅ pip/uv | Python: Better dependency resolution |

## 🚀 **Quick Start**

### **Installation**

```bash
# Complete setup (recommended)
bash .agent/scripts/stagehand-python-helper.sh setup

# Or step by step
bash .agent/scripts/stagehand-python-helper.sh install
bash .agent/scripts/stagehand-python-setup.sh examples
```

### **Basic Usage**

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
        
        # Navigate and interact with natural language
        await page.goto("https://example.com")
        await page.act("scroll down to see more content")
        
        # Extract structured data with Pydantic validation
        data = await page.extract(
            "extract the page title and summary",
            schema=PageData
        )
        
        print(f"Title: {data.title}")
        print(f"Summary: {data.summary}")
        
    finally:
        await stagehand.close()

asyncio.run(main())
```

## 🛠️ **Core Primitives**

### **1. Act - Natural Language Actions**

Execute actions using natural language descriptions:

```python
# Simple actions
await page.act("click the submit button")
await page.act("fill in the email field with user@example.com")
await page.act("scroll down to see more content")

# Complex interactions
await page.act("select 'Premium' from the subscription dropdown")
await page.act("upload the file from the desktop")
```

### **2. Extract - Structured Data with Pydantic**

Pull structured data from pages with schema validation:

```python
from pydantic import BaseModel, Field
from typing import List

class Product(BaseModel):
    name: str = Field(..., description="Product name")
    price: float = Field(..., description="Price in USD")
    rating: float = Field(..., description="Star rating out of 5")
    reviews: List[str] = Field(..., description="Customer review texts")
    in_stock: bool = Field(..., description="Whether item is in stock")

# Extract with validation
products = await page.extract(
    "extract all product details from this page",
    schema=List[Product]
)

for product in products:
    print(f"{product.name}: ${product.price} ({product.rating}⭐)")
```

### **3. Observe - Discover Available Actions**

Find out what actions are possible on the current page:

```python
# Discover all interactive elements
actions = await page.observe()

# Find specific types of actions
buttons = await page.observe("find all clickable buttons")
forms = await page.observe("find all form fields")
links = await page.observe("find navigation links")
```

### **4. Agent - Autonomous Workflows**

Let AI handle entire workflows autonomously:

```python
# Create an autonomous agent
agent = stagehand.agent(
    provider="openai",
    model="computer-use-preview",
    integrations=[],  # Add MCP integrations here
    system_prompt="You are a helpful browser automation agent."
)

# Execute high-level tasks
await agent.execute("complete the checkout process for 2 items")
await agent.execute("find and apply for software engineer jobs")
await agent.execute("research competitor pricing and create a report")
```

## 🔧 **Configuration**

### **Environment Variables**

Create `~/.aidevops/stagehand-python/.env`:

```bash
# AI Provider (choose one)
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_api_key_here
GOOGLE_API_KEY=your_google_api_key_here

# Browser Configuration
STAGEHAND_ENV=LOCAL          # LOCAL or BROWSERBASE
STAGEHAND_HEADLESS=false     # Show browser window
STAGEHAND_VERBOSE=1          # Logging level
STAGEHAND_DEBUG_DOM=true     # Debug DOM interactions

# Model Configuration
MODEL_NAME=google/gemini-2.5-flash-preview-05-20
MODEL_API_KEY=${GOOGLE_API_KEY}

# Optional: Browserbase (for cloud browsers)
BROWSERBASE_API_KEY=your_browserbase_api_key_here
BROWSERBASE_PROJECT_ID=your_browserbase_project_id_here
```

### **Advanced Configuration**

```python
from stagehand import StagehandConfig, Stagehand

config = StagehandConfig(
    env="LOCAL",
    verbose=1,
    debug_dom=True,
    headless=False,
    model_name="google/gemini-2.5-flash-preview-05-20",
    model_api_key=os.getenv("GOOGLE_API_KEY"),
    # Browser options
    browser_options={
        "args": [
            "--disable-web-security",
            "--disable-features=VizDisplayCompositor"
        ]
    }
)

stagehand = Stagehand(config)
```

## 📚 **Examples**

### **E-commerce Automation**

```python
import asyncio
from typing import List
from pydantic import BaseModel, Field
from stagehand import StagehandConfig, Stagehand

class Product(BaseModel):
    name: str = Field(..., description="Product name")
    price: float = Field(..., description="Price in USD")
    rating: float = Field(..., description="Star rating out of 5")
    review_count: int = Field(..., description="Number of reviews")

async def search_products(query: str) -> List[Product]:
    config = StagehandConfig(env="LOCAL", headless=True)
    stagehand = Stagehand(config)
    
    try:
        await stagehand.init()
        page = stagehand.page
        
        await page.goto("https://amazon.com")
        await page.act(f'search for "{query}"')
        
        products = await page.extract(
            "extract the first 5 products with details",
            schema=List[Product]
        )
        
        return products
        
    finally:
        await stagehand.close()

# Usage
products = await search_products("wireless headphones")
for product in products:
    print(f"{product.name}: ${product.price}")
```

### **Data Collection with Error Handling**

```python
import asyncio
import json
from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, Field, ValidationError
from stagehand import StagehandConfig, Stagehand

class Article(BaseModel):
    headline: str = Field(..., description="Article headline")
    summary: str = Field(..., description="Article summary")
    author: Optional[str] = Field(None, description="Article author")
    publish_date: Optional[str] = Field(None, description="Publication date")

async def scrape_news(url: str) -> List[Article]:
    config = StagehandConfig(
        env="LOCAL",
        headless=True,
        verbose=1
    )
    
    stagehand = Stagehand(config)
    
    try:
        await stagehand.init()
        page = stagehand.page
        
        await page.goto(url)
        
        # Handle cookie banners
        try:
            await page.act("accept cookies if there's a banner")
        except Exception:
            pass  # No cookies to handle
        
        articles = await page.extract(
            "extract all news articles with headlines and summaries",
            schema=List[Article]
        )
        
        # Save results with timestamp
        results = {
            "url": url,
            "timestamp": datetime.now().isoformat(),
            "articles": [article.dict() for article in articles]
        }
        
        with open(f"news-{datetime.now().strftime('%Y%m%d_%H%M%S')}.json", 'w') as f:
            json.dump(results, f, indent=2)
        
        return articles
        
    except ValidationError as e:
        print(f"Data validation error: {e}")
        return []
    except Exception as e:
        print(f"Scraping error: {e}")
        return []
    finally:
        await stagehand.close()
```

## 🔗 **MCP Integration**

### **Setup MCP Integration**

```bash
# Setup Python MCP integration
bash .agent/scripts/setup-mcp-integrations.sh stagehand-python

# Setup both JavaScript and Python
bash .agent/scripts/setup-mcp-integrations.sh stagehand-both
```

### **Using MCP with Stagehand Python**

```python
# MCP integration example (when available)
from stagehand import StagehandConfig, Stagehand

config = StagehandConfig(
    env="LOCAL",
    model_name="google/gemini-2.5-flash-preview-05-20",
    model_api_key=os.getenv("GOOGLE_API_KEY")
)

stagehand = Stagehand(config)

# Create agent with MCP integrations
agent = stagehand.agent(
    provider="openai",
    model="computer-use-preview",
    integrations=[
        # MCP integrations will be added here
    ],
    system_prompt="You have access to browser automation and external tools."
)

await agent.execute("Search for information and save it to the database")
```

## 🎯 **Use Cases**

### **🛒 E-commerce & Shopping**

- Product research and price comparison
- Automated purchasing workflows
- Inventory monitoring with Pydantic validation
- Review and rating analysis

### **📊 Data Collection & Research**

- Web scraping with structured data extraction
- Competitive analysis automation
- Market research data gathering with type safety
- Content aggregation with validation

### **🧪 Testing & QA**

- User journey testing with async patterns
- Form validation testing
- Cross-browser compatibility testing
- Accessibility testing with structured reporting

### **💼 Business Process Automation**

- Lead generation workflows
- CRM data entry automation with validation
- Report generation with Pydantic models
- Administrative task automation

## 🔒 **Security & Privacy**

### **Local-First Approach**

- **Complete Privacy**: All automation runs on your local machine
- **No Data Transmission**: Sensitive data never leaves your environment
- **Full Control**: You control all browser instances and data
- **Enterprise Ready**: Perfect for confidential business processes

### **Type Safety**

- **Pydantic Validation**: All extracted data is validated against schemas
- **Runtime Type Checking**: Catch data issues early
- **IDE Support**: Full type hints and autocompletion
- **Error Handling**: Graceful handling of validation errors

## 🛠️ **Helper Commands**

```bash
# Installation and setup
bash .agent/scripts/stagehand-python-helper.sh install      # Install Stagehand Python
bash .agent/scripts/stagehand-python-helper.sh setup       # Complete setup
bash .agent/scripts/stagehand-python-helper.sh status      # Check installation

# Virtual environment management
bash .agent/scripts/stagehand-python-helper.sh activate    # Show activation command
source ~/.aidevops/stagehand-python/.venv/bin/activate  # Activate venv

# Development and testing
bash .agent/scripts/stagehand-python-setup.sh examples  # Create examples
python examples/basic_example.py                        # Run basic example
python examples/ecommerce_automation.py "headphones"    # Run product search

# Maintenance
bash .agent/scripts/stagehand-python-helper.sh clean       # Clean cache and logs
```

## 📖 **Resources**

### **Official Documentation**

- **Stagehand Python Docs**: https://docs.stagehand.dev
- **GitHub Repository**: https://github.com/browserbase/stagehand-python
- **Pydantic Documentation**: https://docs.pydantic.dev

### **AI DevOps Framework Integration**

- **JavaScript Version**: docs/STAGEHAND.md
- **MCP Integrations**: docs/MCP-INTEGRATIONS.md
- **Browser Automation**: docs/BROWSER-AUTOMATION.md

### **Python Ecosystem**

- **AsyncIO Documentation**: https://docs.python.org/3/library/asyncio.html
- **Type Hints Guide**: https://docs.python.org/3/library/typing.html
- **Virtual Environments**: https://docs.python.org/3/tutorial/venv.html

---

**🎉 Ready to revolutionize your browser automation with Python? Get started with Stagehand Python today!**

```bash
bash .agent/scripts/stagehand-python-helper.sh setup
```
