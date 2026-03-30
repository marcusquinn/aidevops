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

## Quick Reference

- **Purpose**: Visual drag-and-drop builder for AI-powered agents and workflows (MIT, commercial OK)
- **Setup**: `bash .agents/scripts/langflow-helper.sh setup`
- **Start/Stop/Status**: `~/.aidevops/scripts/start-langflow.sh` / `stop-langflow.sh` / `langflow-status.sh`
- **URL**: http://localhost:7860 | **API**: http://localhost:7860/docs | **Health**: http://localhost:7860/health
- **Config**: `~/.aidevops/langflow/.env` | **venv**: `~/.aidevops/langflow/venv/`
- **Privacy**: Flows stored locally, optional cloud sync
- **Features**: Flow builder, Python export, MCP server, LangChain, local LLM (Ollama)
- **Docs**: https://docs.langflow.org | **GitHub**: https://github.com/langflow-ai/langflow
- **Community**: [Discord](https://discord.gg/EqksyE2EX9) | [Templates](https://www.langflow.org/templates)

## Installation

Automated (recommended):

```bash
bash .agents/scripts/langflow-helper.sh setup
nano ~/.aidevops/langflow/.env
~/.aidevops/scripts/start-langflow.sh
```

Manual:

```bash
mkdir -p ~/.aidevops/langflow && cd ~/.aidevops/langflow
python3 -m venv venv && source venv/bin/activate
pip install langflow && langflow run
```

Docker:

```bash
docker run -p 7860:7860 langflowai/langflow:latest
docker run -p 7860:7860 -v langflow_data:/app/langflow langflowai/langflow:latest  # persistent
```

Desktop app: https://www.langflow.org/desktop (Windows/macOS)

## Configuration

`~/.aidevops/langflow/.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_key_here   # optional
LANGFLOW_HOST=0.0.0.0
LANGFLOW_PORT=7860
LANGFLOW_WORKERS=1
LANGFLOW_DATABASE_URL=sqlite:///./langflow.db
OLLAMA_BASE_URL=http://localhost:11434
```

Custom components in `~/.aidevops/langflow/components/` — load with `langflow run --components-path ~/.aidevops/langflow/components/`:

```python
from langflow.custom import CustomComponent
from langflow.schema import Data

class MyCustomComponent(CustomComponent):
    display_name = "My Custom Component"
    description = "A custom component for aidevops"
    def build(self, input_text: str) -> Data:
        return Data(text=input_text.upper())
```

## Usage

http://localhost:7860 → New Flow → drag components, connect edges, configure → Run.

RAG pipeline:

```text
[Document Loader] → [Text Splitter] → [Embeddings] → [Vector Store]
                                                           ↓
[User Input] → [Retriever] → [LLM] → [Output]
```

Multi-agent chat:

```text
[User Input] → [Router Agent] → [Specialist Agent 1]
                             → [Specialist Agent 2]
                             → [Aggregator] → [Output]
```

**CrewAI**: Import CrewAI in a custom component to define agents/tasks, connect to Langflow flow components.

## API Integration

```python
import requests
response = requests.post(
    "http://localhost:7860/api/v1/run/<flow-id>",
    json={"input_value": "Hello, world!", "output_type": "chat", "input_type": "chat"}
)
print(response.json())
```

MCP server (`langflow run --mcp` or `LANGFLOW_MCP_ENABLED=true` in `.env`). Claude Code config:

```json
{ "mcpServers": { "langflow": { "command": "langflow", "args": ["run", "--mcp"] } } }
```

## Git Integration

```bash
langflow export --flow-id <flow-id> --output flows/my-flow.json
langflow export --all --output flows/
langflow import --file flows/my-flow.json
langflow import --directory flows/
# .gitignore: langflow.db, *.log, __pycache__/, .env
# Track: flows/*.json, components/*.py
```

## Local LLM Support

- **Ollama**: `curl -fsSL https://ollama.com/install.sh | sh && ollama pull llama3.2` — add Ollama component, set base URL `http://localhost:11434`
- **LM Studio**: https://lmstudio.ai — start local server, use OpenAI-compatible endpoint `http://localhost:1234/v1`

## Deployment

```yaml
services:
  langflow:
    image: langflowai/langflow:latest
    ports: ["7860:7860"]
    volumes:
      - langflow_data:/app/langflow
      - ./flows:/app/flows
    environment: [OPENAI_API_KEY=${OPENAI_API_KEY}]
    restart: unless-stopped
volumes:
  langflow_data:
```

Production: PostgreSQL, auth for multi-user, reverse proxy for HTTPS.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Port in use | `lsof -i :7860` → `kill -9 <PID>` |
| Database errors | `rm ~/.aidevops/langflow/langflow.db && langflow run` |
| Component not loading | `python -c "from components.my_component import MyCustomComponent"` |
| Debug logs | `LANGFLOW_LOG_LEVEL=DEBUG langflow run` or `tail -f ~/.aidevops/langflow/langflow.log` |
