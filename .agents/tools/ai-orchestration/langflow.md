---
description: Langflow visual AI workflow builder - setup, usage, and integration
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

# Langflow - Visual AI Workflow Builder

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Visual drag-and-drop builder for AI-powered agents and workflows
- **License**: MIT (fully open-source, commercial use permitted)
- **Setup**: `bash .agent/scripts/langflow-helper.sh setup`
- **Start**: `~/.aidevops/scripts/start-langflow.sh`
- **Stop**: `~/.aidevops/scripts/stop-langflow.sh`
- **Status**: `~/.aidevops/scripts/langflow-status.sh`
- **URL**: http://localhost:7860
- **Config**: `~/.aidevops/langflow/.env`
- **Install**: `pip install langflow` in venv at `~/.aidevops/langflow/venv/`
- **Privacy**: Flows stored locally, optional cloud sync

**Key Features**:

- Drag-and-drop visual flow builder
- Export flows to Python code
- Built-in MCP server support
- LangChain ecosystem integration
- Local LLM support (Ollama)

<!-- AI-CONTEXT-END -->

## Overview

Langflow is a powerful visual tool for building and deploying AI-powered agents and workflows. It provides developers with both a visual authoring experience and built-in API/MCP servers that turn every workflow into a tool.

## Installation

### Automated Setup (Recommended)

```bash
# Run the setup script
bash .agent/scripts/langflow-helper.sh setup

# Configure API keys
nano ~/.aidevops/langflow/.env

# Start Langflow
~/.aidevops/scripts/start-langflow.sh
```

### Manual Installation

```bash
# Create directory and virtual environment
mkdir -p ~/.aidevops/langflow
cd ~/.aidevops/langflow
python3 -m venv venv
source venv/bin/activate

# Install Langflow
pip install langflow

# Run Langflow
langflow run
```

### Docker Installation

```bash
# Run with Docker
docker run -p 7860:7860 langflowai/langflow:latest

# With persistent storage
docker run -p 7860:7860 -v langflow_data:/app/langflow langflowai/langflow:latest
```

### Desktop App

Download Langflow Desktop from https://www.langflow.org/desktop for Windows/macOS.

## Configuration

### Environment Variables

Create `~/.aidevops/langflow/.env`:

```bash
# OpenAI Configuration
OPENAI_API_KEY=your_openai_api_key_here

# Anthropic Configuration (optional)
ANTHROPIC_API_KEY=your_anthropic_key_here

# Langflow Configuration
LANGFLOW_HOST=0.0.0.0
LANGFLOW_PORT=7860
LANGFLOW_WORKERS=1

# Database (default: SQLite)
LANGFLOW_DATABASE_URL=sqlite:///./langflow.db

# Local LLM (Ollama)
OLLAMA_BASE_URL=http://localhost:11434
```

### Custom Components

Create custom components in Python:

```python
# ~/.aidevops/langflow/components/my_component.py
from langflow.custom import CustomComponent
from langflow.schema import Data

class MyCustomComponent(CustomComponent):
    display_name = "My Custom Component"
    description = "A custom component for aidevops"
    
    def build(self, input_text: str) -> Data:
        # Your custom logic here
        result = input_text.upper()
        return Data(text=result)
```

Load custom components:

```bash
langflow run --components-path ~/.aidevops/langflow/components/
```

## Usage

### Starting Services

```bash
# Start Langflow
~/.aidevops/scripts/start-langflow.sh

# Check status
~/.aidevops/scripts/langflow-status.sh

# Stop Langflow
~/.aidevops/scripts/stop-langflow.sh
```

### Accessing the Interface

- **Web UI**: http://localhost:7860
- **API Docs**: http://localhost:7860/docs
- **Health Check**: http://localhost:7860/health

### Building Your First Flow

1. Open http://localhost:7860
2. Click "New Flow" or use a template
3. Drag components from the sidebar
4. Connect components by dragging edges
5. Configure each component's parameters
6. Click "Run" to test the flow

### Common Flow Patterns

**RAG Pipeline**:

```text
[Document Loader] → [Text Splitter] → [Embeddings] → [Vector Store]
                                                           ↓
[User Input] → [Retriever] → [LLM] → [Output]
```

**Multi-Agent Chat**:

```text
[User Input] → [Router Agent] → [Specialist Agent 1]
                             → [Specialist Agent 2]
                             → [Aggregator] → [Output]
```

## API Integration

### REST API

```python
import requests

# Run a flow
response = requests.post(
    "http://localhost:7860/api/v1/run/<flow-id>",
    json={
        "input_value": "Hello, world!",
        "output_type": "chat",
        "input_type": "chat"
    }
)
print(response.json())
```

### MCP Server

Langflow can expose flows as MCP tools:

```bash
# Start with MCP server enabled
langflow run --mcp

# Or configure in .env
LANGFLOW_MCP_ENABLED=true
```

Then connect from AI assistants that support MCP.

## Git Integration

### Exporting Flows

```bash
# Export a flow to JSON
langflow export --flow-id <flow-id> --output flows/my-flow.json

# Export all flows
langflow export --all --output flows/
```

### Importing Flows

```bash
# Import a flow from JSON
langflow import --file flows/my-flow.json

# Import all flows from directory
langflow import --directory flows/
```

### Version Control Best Practices

```bash
# .gitignore additions
langflow.db
*.log
__pycache__/
.env

# Track these
flows/*.json
components/*.py
```

### Bi-directional Sync

Use file watchers for automatic sync:

```python
# sync_flows.py
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import subprocess

class FlowSyncHandler(FileSystemEventHandler):
    def on_modified(self, event):
        if event.src_path.endswith('.json'):
            subprocess.run(['langflow', 'import', '--file', event.src_path])

# Run with: python sync_flows.py
```

## Local LLM Support

### Using Ollama

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model
ollama pull llama3.2
ollama pull codellama

# Configure in Langflow
# Add Ollama component and set base URL to http://localhost:11434
```

### Using LM Studio

1. Download LM Studio from https://lmstudio.ai
2. Load a model and start the local server
3. In Langflow, use OpenAI-compatible endpoint: http://localhost:1234/v1

## Deployment

### Docker Compose

```yaml
# docker-compose.yml
version: '3.8'
services:
  langflow:
    image: langflowai/langflow:latest
    ports:
      - "7860:7860"
    volumes:
      - langflow_data:/app/langflow
      - ./flows:/app/flows
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
    restart: unless-stopped

volumes:
  langflow_data:
```

### Production Considerations

- Use PostgreSQL instead of SQLite for production
- Enable authentication for multi-user deployments
- Use reverse proxy (nginx/traefik) for HTTPS
- Set up monitoring and logging

## Troubleshooting

### Common Issues

**Port already in use**:

```bash
# Find and kill process
lsof -i :7860
kill -9 <PID>
```

**Database errors**:

```bash
# Reset database
rm ~/.aidevops/langflow/langflow.db
langflow run
```

**Component not loading**:

```bash
# Check component syntax
python -c "from components.my_component import MyCustomComponent"
```

### Logs

```bash
# View logs
tail -f ~/.aidevops/langflow/langflow.log

# Debug mode
LANGFLOW_LOG_LEVEL=DEBUG langflow run
```

## Integration Examples

### With aidevops Workflows

```bash
# Export flow for version control
langflow export --flow-id <id> --output flows/devops-automation.json

# Commit to git
git add flows/devops-automation.json
git commit -m "feat: add DevOps automation flow"
```

### With CrewAI

Langflow can orchestrate CrewAI agents:

1. Create a custom component that imports CrewAI
2. Define agents and tasks in the component
3. Connect to other Langflow components

### With OpenCode

Use Langflow flows as tools in OpenCode via MCP:

```json
{
  "mcpServers": {
    "langflow": {
      "command": "langflow",
      "args": ["run", "--mcp"]
    }
  }
}
```

## Resources

- **Documentation**: https://docs.langflow.org
- **GitHub**: https://github.com/langflow-ai/langflow
- **Discord**: https://discord.gg/EqksyE2EX9
- **Templates**: https://www.langflow.org/templates
