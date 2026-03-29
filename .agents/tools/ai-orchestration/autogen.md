---
description: Microsoft AutoGen multi-agent framework - setup, usage, and integration
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# AutoGen - Agentic AI Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Microsoft multi-agent AI framework — autonomous or human-in-the-loop
- **License**: MIT (code) / CC-BY-4.0 (docs)
- **Setup**: `bash .agents/scripts/autogen-helper.sh setup` → edit `~/.aidevops/autogen/.env` → `~/.aidevops/scripts/start-autogen-studio.sh`
- **Stop/Status**: `~/.aidevops/scripts/stop-autogen-studio.sh`, `autogen-status.sh`
- **Studio**: http://localhost:8081 | `autogenstudio ui --port 8081 --appdir ./my-app`
- **Install**: `pip install autogen-agentchat autogen-ext[openai]`
- **Architecture**: Core API (message passing, event-driven, distributed) → AgentChat API (rapid prototyping) → Extensions API. Python + .NET.
- **.NET**: `Microsoft.AutoGen.Contracts` + `Microsoft.AutoGen.Core` — same `AssistantAgent` pattern.

<!-- AI-CONTEXT-END -->

## Installation

```bash
mkdir -p ~/.aidevops/autogen && cd ~/.aidevops/autogen
python3 -m venv venv && source venv/bin/activate
pip install autogen-agentchat autogen-ext[openai] autogenstudio
autogenstudio ui --port 8081
```

## Configuration

`~/.aidevops/autogen/.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_key_here        # Optional
AZURE_OPENAI_API_KEY=your_azure_key_here         # Optional
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/
OLLAMA_BASE_URL=http://localhost:11434            # Local LLM
AUTOGEN_STUDIO_PORT=8081
```

## Usage

```python
# Common imports — add per-example extras as shown below
import asyncio
from autogen_agentchat.agents import AssistantAgent
from autogen_ext.models.openai import OpenAIChatCompletionClient
```

### Basic Agent

```python
async def main():
    client = OpenAIChatCompletionClient(model="gpt-4.1")
    agent = AssistantAgent("assistant", model_client=client)
    print(await agent.run(task="Say 'Hello World!'"))
    await client.close()
asyncio.run(main())
```

### MCP Server Integration

```python
from autogen_ext.tools.mcp import McpWorkbench, StdioServerParams
from autogen_agentchat.ui import Console

async def main():
    client = OpenAIChatCompletionClient(model="gpt-4.1")
    params = StdioServerParams(command="npx", args=["@playwright/mcp@latest", "--headless"])
    async with McpWorkbench(params) as mcp:
        agent = AssistantAgent("web_assistant", model_client=client,
                               workbench=mcp, model_client_stream=True, max_tool_iterations=10)
        await Console(agent.run_stream(task="Search for AutoGen documentation"))
asyncio.run(main())
```

### Multi-Agent with AgentTool

```python
from autogen_agentchat.tools import AgentTool
from autogen_agentchat.ui import Console

async def main():
    client = OpenAIChatCompletionClient(model="gpt-4.1")
    math = AssistantAgent("math_expert", model_client=client,
        system_message="You are a math expert.", description="Math expert.", model_client_stream=True)
    chem = AssistantAgent("chemistry_expert", model_client=client,
        system_message="You are a chemistry expert.", description="Chemistry expert.", model_client_stream=True)
    lead = AssistantAgent("assistant", model_client=client, model_client_stream=True,
        system_message="General assistant. Use expert tools when needed.",
        tools=[AgentTool(math, return_value_as_last_message=True),
               AgentTool(chem, return_value_as_last_message=True)], max_tool_iterations=10)
    await Console(lead.run_stream(task="What is the integral of x^2?"))
asyncio.run(main())
```

## Alternative Model Clients

```python
# Ollama (local)
from autogen_ext.models.ollama import OllamaChatCompletionClient
client = OllamaChatCompletionClient(model="llama3.2", base_url="http://localhost:11434")

# Azure OpenAI
from autogen_ext.models.openai import AzureOpenAIChatCompletionClient
client = AzureOpenAIChatCompletionClient(
    model="gpt-4", azure_endpoint="https://your-resource.openai.azure.com/",
    api_version="2024-02-15-preview")
```

## Deployment

**Docker:**

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY . .
RUN pip install autogen-agentchat autogen-ext[openai]
CMD ["python", "main.py"]
```

For web frameworks (FastAPI etc.), wrap agent patterns in route handlers. Always call `await client.close()` after each request.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Import errors | `pip install autogen-agentchat autogen-ext[openai]` |
| Async errors | Wrap with `asyncio.run(main())` |
| Client not closing | `await client.close()` or `async with client:` |
| Upgrading from v0.2 | [Migration Guide](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/migration-guide.html) |

## Resources

- [Docs](https://microsoft.github.io/autogen/) | [GitHub](https://github.com/microsoft/autogen) | [Discord](https://aka.ms/autogen-discord) | [Blog](https://devblogs.microsoft.com/autogen/) | [PyPI](https://pypi.org/project/autogen-agentchat/)
