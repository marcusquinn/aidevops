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

- **Purpose**: Programming framework for agentic AI with multi-language support
- **License**: MIT (code) / CC-BY-4.0 (docs)
- **Setup**: `bash .agent/scripts/autogen-helper.sh setup`
- **Start**: `~/.aidevops/scripts/start-autogen-studio.sh`
- **Stop**: `~/.aidevops/scripts/stop-autogen-studio.sh`
- **Status**: `~/.aidevops/scripts/autogen-status.sh`
- **URL**: http://localhost:8081 (AutoGen Studio)
- **Config**: `~/.aidevops/autogen/.env`
- **Install**: `pip install autogen-agentchat autogen-ext[openai]`

**Key Features**:

- Multi-language support (Python, .NET)
- MCP server integration
- Human-in-the-loop workflows
- AgentChat for rapid prototyping
- Core API for advanced control

<!-- AI-CONTEXT-END -->

## Overview

AutoGen is a framework from Microsoft for creating multi-agent AI applications that can act autonomously or work alongside humans. It provides both high-level APIs for rapid prototyping and low-level control for production systems.

## Architecture

AutoGen uses a layered design:

- **Core API**: Message passing, event-driven agents, distributed runtime
- **AgentChat API**: Simpler API for rapid prototyping
- **Extensions API**: First and third-party extensions

## Installation

### Automated Setup (Recommended)

```bash
# Run the setup script
bash .agent/scripts/autogen-helper.sh setup

# Configure API keys
nano ~/.aidevops/autogen/.env

# Start AutoGen Studio
~/.aidevops/scripts/start-autogen-studio.sh
```

### Manual Installation

```bash
# Create directory and virtual environment
mkdir -p ~/.aidevops/autogen
cd ~/.aidevops/autogen
python3 -m venv venv
source venv/bin/activate

# Install AutoGen
pip install autogen-agentchat autogen-ext[openai]

# Install AutoGen Studio
pip install autogenstudio
```

### Quick Start

```bash
# Export your API key
export OPENAI_API_KEY="sk-..."

# Run AutoGen Studio
autogenstudio ui --port 8081
```

## Configuration

### Environment Variables

Create `~/.aidevops/autogen/.env`:

```bash
# OpenAI Configuration (Required)
OPENAI_API_KEY=your_openai_api_key_here

# Anthropic Configuration (Optional)
ANTHROPIC_API_KEY=your_anthropic_key_here

# Azure OpenAI (Optional)
AZURE_OPENAI_API_KEY=your_azure_key_here
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/

# Local LLM (Ollama)
OLLAMA_BASE_URL=http://localhost:11434

# AutoGen Studio Configuration
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
    
    # Connect to MCP server
    server_params = StdioServerParams(
        command="npx",
        args=["@playwright/mcp@latest", "--headless"]
    )
    
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

    # Create specialist agents
    math_agent = AssistantAgent(
        "math_expert",
        model_client=model_client,
        system_message="You are a math expert.",
        description="A math expert assistant.",
        model_client_stream=True
    )
    math_tool = AgentTool(math_agent, return_value_as_last_message=True)

    chemistry_agent = AssistantAgent(
        "chemistry_expert",
        model_client=model_client,
        system_message="You are a chemistry expert.",
        description="A chemistry expert assistant.",
        model_client_stream=True
    )
    chemistry_tool = AgentTool(chemistry_agent, return_value_as_last_message=True)

    # Create orchestrator agent
    orchestrator = AssistantAgent(
        "assistant",
        system_message="You are a general assistant. Use expert tools when needed.",
        model_client=model_client,
        model_client_stream=True,
        tools=[math_tool, chemistry_tool],
        max_tool_iterations=10
    )
    
    await Console(orchestrator.run_stream(task="What is the integral of x^2?"))
    await Console(orchestrator.run_stream(task="What is the molecular weight of water?"))

asyncio.run(main())
```

### AutoGen Studio (GUI)

```bash
# Start AutoGen Studio
autogenstudio ui --port 8081 --appdir ./my-app

# Access at http://localhost:8081
```

AutoGen Studio provides a no-code GUI for:

- Building multi-agent workflows
- Testing agent interactions
- Prototyping without writing code

## Local LLM Support

### Using Ollama

```python
from autogen_ext.models.ollama import OllamaChatCompletionClient

model_client = OllamaChatCompletionClient(
    model="llama3.2",
    base_url="http://localhost:11434"
)
```

### Using Azure OpenAI

```python
from autogen_ext.models.openai import AzureOpenAIChatCompletionClient

model_client = AzureOpenAIChatCompletionClient(
    model="gpt-4",
    azure_endpoint="https://your-resource.openai.azure.com/",
    api_version="2024-02-15-preview"
)
```

## .NET Support

AutoGen also supports .NET for cross-language development:

```csharp
using Microsoft.AutoGen.Contracts;
using Microsoft.AutoGen.Core;

// Create an agent in .NET
var agent = new AssistantAgent("assistant", modelClient);
var result = await agent.RunAsync("Hello from .NET!");
```

## Git Integration

### Project Structure

```text
my-autogen-project/
├── .env                    # gitignored
├── agents/
│   ├── researcher.py
│   └── writer.py
├── workflows/
│   └── research_flow.py
└── config/
    └── settings.json       # version controlled
```

### Version Control Best Practices

```bash
# .gitignore
.env
__pycache__/
*.pyc
.venv/
venv/
*.log
.autogen/
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

### FastAPI Integration

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

## Integration Examples

### With aidevops Workflows

```python
# DevOps automation with AutoGen
from autogen_agentchat.agents import AssistantAgent
from autogen_agentchat.tools import AgentTool

# Create specialized DevOps agents
code_reviewer = AssistantAgent(
    "code_reviewer",
    system_message="You review code for quality and security issues."
)

deployment_agent = AssistantAgent(
    "deployment_agent", 
    system_message="You handle deployment tasks and CI/CD."
)

# Orchestrate DevOps workflow
devops_orchestrator = AssistantAgent(
    "devops_lead",
    tools=[
        AgentTool(code_reviewer),
        AgentTool(deployment_agent)
    ]
)
```

### With Langflow

AutoGen agents can be wrapped as Langflow custom components.

### With CrewAI

Both frameworks can be used together - AutoGen for conversational flows, CrewAI for role-based teams.

## Troubleshooting

### Common Issues

**Import errors**:

```bash
# Ensure packages are installed
pip install autogen-agentchat autogen-ext[openai]
```

**Async errors**:

```python
# Always use asyncio.run() for async code
import asyncio
asyncio.run(main())
```

**Model client not closing**:

```python
# Always close model clients
await model_client.close()

# Or use context manager
async with model_client:
    # ... use client
```

### Migration from v0.2

If upgrading from AutoGen v0.2, see the [Migration Guide](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/migration-guide.html).

## Resources

- **Documentation**: https://microsoft.github.io/autogen/
- **GitHub**: https://github.com/microsoft/autogen
- **Discord**: https://aka.ms/autogen-discord
- **Blog**: https://devblogs.microsoft.com/autogen/
- **PyPI**: https://pypi.org/project/autogen-agentchat/
