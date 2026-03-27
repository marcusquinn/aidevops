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

- **Purpose**: Microsoft framework for multi-agent AI — autonomous or human-in-the-loop
- **License**: MIT (code) / CC-BY-4.0 (docs)
- **Setup**: `bash .agents/scripts/autogen-helper.sh setup`
- **Start**: `~/.aidevops/scripts/start-autogen-studio.sh`
- **Stop**: `~/.aidevops/scripts/stop-autogen-studio.sh`
- **Status**: `~/.aidevops/scripts/autogen-status.sh`
- **URL**: http://localhost:8081 (AutoGen Studio)
- **Config**: `~/.aidevops/autogen/.env`
- **Install**: `pip install autogen-agentchat autogen-ext[openai]`

**Architecture layers**: Core API (message passing, event-driven, distributed) → AgentChat API (rapid prototyping) → Extensions API (first/third-party). Multi-language: Python + .NET.

<!-- AI-CONTEXT-END -->

## Installation

### Automated Setup (Recommended)

```bash
bash .agents/scripts/autogen-helper.sh setup
nano ~/.aidevops/autogen/.env
~/.aidevops/scripts/start-autogen-studio.sh
```

### Manual

```bash
mkdir -p ~/.aidevops/autogen && cd ~/.aidevops/autogen
python3 -m venv venv && source venv/bin/activate
pip install autogen-agentchat autogen-ext[openai] autogenstudio
autogenstudio ui --port 8081
```

## Configuration

Create `~/.aidevops/autogen/.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_key_here        # Optional
AZURE_OPENAI_API_KEY=your_azure_key_here         # Optional
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/
OLLAMA_BASE_URL=http://localhost:11434            # Local LLM
AUTOGEN_STUDIO_PORT=8081
```

## Usage

### Hello World

```python
import asyncio
from autogen_agentchat.agents import AssistantAgent
from autogen_ext.models.openai import OpenAIChatCompletionClient

async def main():
    model_client = OpenAIChatCompletionClient(model="gpt-4.1")
    agent = AssistantAgent("assistant", model_client=model_client)
    print(await agent.run(task="Say 'Hello World!'"))
    await model_client.close()

asyncio.run(main())
```

### MCP Server Integration

```python
import asyncio
from autogen_agentchat.agents import AssistantAgent
from autogen_agentchat.ui import Console
from autogen_ext.models.openai import OpenAIChatCompletionClient
from autogen_ext.tools.mcp import McpWorkbench, StdioServerParams

async def main():
    model_client = OpenAIChatCompletionClient(model="gpt-4.1")
    server_params = StdioServerParams(command="npx", args=["@playwright/mcp@latest", "--headless"])
    async with McpWorkbench(server_params) as mcp:
        agent = AssistantAgent(
            "web_assistant",
            model_client=model_client,
            workbench=mcp,
            model_client_stream=True,
            max_tool_iterations=10
        )
        await Console(agent.run_stream(task="Search for AutoGen documentation"))

asyncio.run(main())
```

### Multi-Agent Orchestration

```python
import asyncio
from autogen_agentchat.agents import AssistantAgent
from autogen_agentchat.tools import AgentTool
from autogen_agentchat.ui import Console
from autogen_ext.models.openai import OpenAIChatCompletionClient

async def main():
    model_client = OpenAIChatCompletionClient(model="gpt-4.1")

    math_agent = AssistantAgent(
        "math_expert", model_client=model_client,
        system_message="You are a math expert.",
        description="A math expert assistant.", model_client_stream=True
    )
    chemistry_agent = AssistantAgent(
        "chemistry_expert", model_client=model_client,
        system_message="You are a chemistry expert.",
        description="A chemistry expert assistant.", model_client_stream=True
    )
    orchestrator = AssistantAgent(
        "assistant",
        system_message="You are a general assistant. Use expert tools when needed.",
        model_client=model_client, model_client_stream=True,
        tools=[AgentTool(math_agent, return_value_as_last_message=True),
               AgentTool(chemistry_agent, return_value_as_last_message=True)],
        max_tool_iterations=10
    )
    await Console(orchestrator.run_stream(task="What is the integral of x^2?"))

asyncio.run(main())
```

### AutoGen Studio (GUI)

No-code GUI for building and testing multi-agent workflows.

```bash
autogenstudio ui --port 8081 --appdir ./my-app
# Access at http://localhost:8081
```

## Local LLM Support

```python
# Ollama
from autogen_ext.models.ollama import OllamaChatCompletionClient
model_client = OllamaChatCompletionClient(model="llama3.2", base_url="http://localhost:11434")

# Azure OpenAI
from autogen_ext.models.openai import AzureOpenAIChatCompletionClient
model_client = AzureOpenAIChatCompletionClient(
    model="gpt-4",
    azure_endpoint="https://your-resource.openai.azure.com/",
    api_version="2024-02-15-preview"
)
```

## .NET Support

```csharp
using Microsoft.AutoGen.Contracts;
using Microsoft.AutoGen.Core;

var agent = new AssistantAgent("assistant", modelClient);
var result = await agent.RunAsync("Hello from .NET!");
```

## Deployment

### Docker

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY . .
RUN pip install autogen-agentchat autogen-ext[openai]
CMD ["python", "main.py"]
```

### FastAPI

```python
from fastapi import FastAPI
from autogen_agentchat.agents import AssistantAgent
from autogen_ext.models.openai import OpenAIChatCompletionClient

app = FastAPI()

@app.post("/chat")
async def chat(message: str):
    model_client = OpenAIChatCompletionClient(model="gpt-4o-mini")
    agent = AssistantAgent("assistant", model_client=model_client)
    result = await agent.run(task=message)
    await model_client.close()
    return {"response": str(result)}
```

## Integration with aidevops

```python
from autogen_agentchat.agents import AssistantAgent
from autogen_agentchat.tools import AgentTool

code_reviewer = AssistantAgent("code_reviewer",
    system_message="You review code for quality and security issues.")
deployment_agent = AssistantAgent("deployment_agent",
    system_message="You handle deployment tasks and CI/CD.")
devops_orchestrator = AssistantAgent("devops_lead",
    tools=[AgentTool(code_reviewer), AgentTool(deployment_agent)])
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Import errors | `pip install autogen-agentchat autogen-ext[openai]` |
| Async errors | Wrap entry point with `asyncio.run(main())` |
| Model client not closing | `await model_client.close()` or use `async with model_client:` |
| Upgrading from v0.2 | See [Migration Guide](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/migration-guide.html) |

## Resources

- **Documentation**: https://microsoft.github.io/autogen/
- **GitHub**: https://github.com/microsoft/autogen
- **Discord**: https://aka.ms/autogen-discord
- **Blog**: https://devblogs.microsoft.com/autogen/
- **PyPI**: https://pypi.org/project/autogen-agentchat/
