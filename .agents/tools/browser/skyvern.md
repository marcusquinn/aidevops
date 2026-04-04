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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Skyvern

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Automate browser workflows using computer vision + LLM (no DOM selectors needed)
- **Install**: Docker (recommended) or `pip install skyvern`
- **Repo**: https://github.com/Skyvern-AI/skyvern (20k+ stars, Python, AGPL-3.0)
- **Docs**: https://docs.skyvern.com/
- **Cloud**: https://app.skyvern.com/ (managed, no self-hosting required)
- **Version**: 0.1.x (check repo for latest)
- **Key capabilities**: Visual element detection (screenshots, not selectors), built-in CAPTCHA solving (2captcha, Anti-Captcha), proxy rotation, workflow chaining with parameter passing, structured JSON extraction via natural language goals, self-hosted or managed cloud (pay-per-task)

**When to use**: Sites you don't control with frequently changing DOM, visual-only UIs (canvas, iframes, dynamic SPAs), or CAPTCHAs. Skyvern uses screenshots + LLM vision to identify and interact with elements.

**When to prefer other tools**:

- **Testing your own app**: Playwright — faster, deterministic, no LLM cost
- **AI-native multi-step tasks**: browser-use — better Python integration, MIT license
- **Natural language on known pages**: Stagehand — TypeScript-native, Browserbase cloud
- **Bulk scraping**: Crawl4AI — optimised for content extraction at scale
- **Persistent browser sessions**: dev-browser — preserves logins across sessions

<!-- AI-CONTEXT-END -->

## Setup

### Docker (recommended)

```bash
git clone https://github.com/Skyvern-AI/skyvern.git
cd skyvern
docker compose up -d
# API: http://localhost:8000 | UI: http://localhost:8080
```

### pip (local development)

```bash
pip install skyvern
skyvern init    # Downloads browser, sets up DB
skyvern up      # Start server
```

### Environment

```bash
# .env
OPENAI_API_KEY=your-key                    # Required (vision LLM)
# ANTHROPIC_API_KEY=your-key              # Alternative LLM provider
SKYVERN_API_KEY=<token-from-skyvern-init>  # JWT for self-hosted API auth
```

## API Usage

### Task Creation and Polling

```python
import requests
import time

BASE_URL = "http://localhost:8000"
HEADERS = {"x-api-key": "your-api-key"}

# Create a task
response = requests.post(
    f"{BASE_URL}/api/v1/tasks",
    headers=HEADERS,
    json={
        "url": "https://example.com/login",
        "navigation_goal": "Log in with username 'user@example.com' and password stored in the PASSWORD env var, then navigate to the account settings page",
        "data_extraction_goal": "Extract the account email, plan type, and billing cycle",
        "proxy_location": "RESIDENTIAL",  # Optional: residential proxy
        "max_steps_override": 20,          # Optional: cap steps (default 10)
    },
)
task_id = response.json()["task_id"]

# Poll for completion
while True:
    task = requests.get(f"{BASE_URL}/api/v1/tasks/{task_id}", headers=HEADERS).json()
    if task["status"] in ("completed", "failed", "terminated"):
        break
    time.sleep(2)

if task["status"] == "completed":
    extracted = task.get("extracted_information")
    print(extracted if extracted is not None else "No data extracted (data_extraction_goal may not have been set).")
else:
    print(f"Task ended: {task['status']}")
    if task.get("error_message"):
        print(f"Error: {task['error_message']}")
```

### Task Status Values

| Status | Meaning |
|--------|---------|
| `created` | Queued, not yet started |
| `running` | Browser executing steps |
| `completed` | All goals achieved |
| `failed` | Could not complete goal |
| `terminated` | Manually stopped |

### Workflow API (multi-step sequences)

```python
# Create reusable workflow
workflow = requests.post(
    f"{BASE_URL}/api/v1/workflows",
    headers=HEADERS,
    json={
        "title": "Login and extract data",
        "description": "Logs in and extracts account info",
        "workflow_definition": {
            "blocks": [
                {
                    "block_type": "task",
                    "label": "login",
                    "url": "https://example.com/login",
                    "navigation_goal": "Log in with the provided credentials",
                    "data_extraction_goal": None,
                    "parameter_keys": ["username", "password"],
                },
                {
                    "block_type": "task",
                    "label": "extract",
                    "url": "https://example.com/account",
                    "navigation_goal": "Navigate to account settings",
                    "data_extraction_goal": "Extract plan type and billing date",
                },
            ]
        },
    },
)
workflow_id = workflow.json()["workflow_id"]

# Run with parameters
run = requests.post(
    f"{BASE_URL}/api/v1/workflows/{workflow_id}/run",
    headers=HEADERS,
    json={"data": {"username": "user@example.com", "password": "secret"}},
)
```

### Use Case Patterns

**Forms with CAPTCHAs** — Skyvern's primary strength (visual CAPTCHAs that break DOM-based tools):

```python
requests.post(f"{BASE_URL}/api/v1/tasks", headers=HEADERS, json={
    "url": "https://example.com/signup",
    "navigation_goal": "Fill in the signup form with name 'Test User', email 'test@example.com', and solve any CAPTCHA that appears",
    "data_extraction_goal": "Confirm the account was created successfully",
})
```

**Dynamic SPAs** — waits for visual stability before acting:

```python
requests.post(f"{BASE_URL}/api/v1/tasks", headers=HEADERS, json={
    "url": "https://app.example.com/dashboard",
    "navigation_goal": "Click the 'Export' button and wait for the download to complete",
    "data_extraction_goal": "Extract the export filename shown in the confirmation dialog",
})
```

**Visual-only UIs** — canvas-based apps, embedded iframes, no accessible DOM:

```python
requests.post(f"{BASE_URL}/api/v1/tasks", headers=HEADERS, json={
    "url": "https://example.com/chart-editor",
    "navigation_goal": "Click the bar chart element in the top-left quadrant and change its colour to blue",
})
```

## Comparison

### Self-Hosted vs Skyvern Cloud

| Aspect | Self-Hosted | Skyvern Cloud |
|--------|-------------|---------------|
| Setup | Docker Compose, ~10 min | API key only |
| Cost | LLM API costs only | Per-task pricing |
| Data privacy | Full control | Data sent to Skyvern |
| Scaling | Manual (add workers) | Automatic |
| CAPTCHA solving | Configure own service | Included |
| Proxy rotation | Configure own proxies | Included |
| Best for | High volume, sensitive data | Quick start, low volume |

### vs Other Browser Tools

| Feature | Skyvern | browser-use | Playwright | Stagehand |
|---------|---------|-------------|------------|-----------|
| Vision AI | Primary (screenshots) | Hybrid (vision + DOM) | No | Yes (DOM-first) |
| No selectors needed | Yes | Yes | No | Yes |
| API-first | Yes | No | No | No |
| Workflow YAML/JSON | Yes | No | No | No |
| CAPTCHA handling | Built-in | Via Cloud | No | No |
| Self-hosted | Yes | Yes | Yes | No (Browserbase) |
| License | AGPL-3.0 | MIT | Apache-2.0 | MIT |
| Language | Python | Python | Any | TypeScript |
| Best for | Resilient automation, CAPTCHAs | AI-native tasks | Testing, speed | Natural language on known pages |

## Related

- `tools/browser/browser-automation.md` - Browser tool decision tree
- `tools/browser/browser-use.md` - AI-native browser automation (MIT, Python)
- `tools/browser/playwright.md` - Playwright direct automation
- `tools/browser/stagehand.md` - Stagehand AI browser automation (TypeScript)
- `tools/browser/crawl4ai.md` - Bulk web scraping and content extraction
