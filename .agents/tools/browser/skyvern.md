---
description: Skyvern - computer vision browser automation for web workflows
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  webfetch: true
---

# Skyvern

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Automate browser workflows using computer vision (no selectors needed)
- **Install**: `pip install skyvern` or Docker
- **Repo**: https://github.com/Skyvern-AI/skyvern (20k+ stars, Python, AGPL-3.0)
- **Docs**: https://docs.skyvern.com/

**When to use**: Automating workflows on websites you don't control, where DOM structure changes frequently. Skyvern uses visual understanding to interact with pages, making it resilient to UI changes.

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Docker (recommended)
docker run -p 8000:8000 skyvern/skyvern

# Or pip
pip install skyvern
skyvern init
skyvern up
```

## API Usage

```python
import requests

# Create a task
response = requests.post("http://localhost:8000/api/v1/tasks", json={
    "url": "https://example.com/login",
    "navigation_goal": "Log in with username 'user' and password 'pass', then navigate to settings",
    "data_extraction_goal": "Extract the account email and plan type",
})

task_id = response.json()["task_id"]

# Check status
status = requests.get(f"http://localhost:8000/api/v1/tasks/{task_id}")
print(status.json())
```

## Key Features

- **Visual element detection**: Identifies buttons, forms, and links by appearance
- **Workflow chaining**: Multi-step task sequences with conditional logic
- **Data extraction**: Extract structured data from any page
- **CAPTCHA handling**: Built-in CAPTCHA solving integration
- **Proxy support**: Rotate proxies for scraping at scale
- **Self-hosted**: Full control over data and execution

## Workflow Definition

```yaml
# skyvern-workflow.yaml
steps:
  - type: navigate
    url: "https://example.com"
  - type: click
    element: "Sign In button"
  - type: input
    element: "Email field"
    value: "user@example.com"
  - type: click
    element: "Submit button"
  - type: extract
    goal: "Get the dashboard summary data"
```

## Comparison

| Feature | Skyvern | browser-use | Playwright |
|---------|---------|-------------|------------|
| Visual AI | Primary | Hybrid | No |
| Self-hosted | Yes | Yes | Yes |
| API-first | Yes | No | No |
| Workflow YAML | Yes | No | No |
| License | AGPL-3.0 | MIT | Apache-2.0 |
| Best for | Resilient automation | AI tasks | Testing |

## Related

- `tools/browser/browser-automation.md` - Browser tool decision tree
- `tools/browser/browser-use.md` - AI-native browser automation
- `tools/browser/playwright.md` - Playwright direct automation
