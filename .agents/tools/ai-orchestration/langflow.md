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

- **Purpose**: Visual drag-and-drop builder for AI agents and workflows (MIT, commercial OK)
- **Setup**: `bash .agents/scripts/langflow-helper.sh setup` → edit `~/.aidevops/langflow/.env` → `~/.aidevops/scripts/start-langflow.sh`
- **Lifecycle**: `start-langflow.sh` / `stop-langflow.sh` / `langflow-status.sh` (all in `~/.aidevops/scripts/`)
- **Endpoints**: localhost:7860 (UI) | `/docs` (API) | `/health` (health check)
- **Config**: `~/.aidevops/langflow/.env` | **venv**: `~/.aidevops/langflow/venv/`
- **Privacy**: Flows stored locally, optional cloud sync
- **Docs**: <https://docs.langflow.org> | **GitHub**: <https://github.com/langflow-ai/langflow>
- **Community**: [Discord](https://discord.gg/EqksyE2EX9) | [Templates](https://www.langflow.org/templates)

## Installation

Automated (recommended) — runs setup, prompts for `.env` config, starts server:

```bash
bash .agents/scripts/langflow-helper.sh setup
```

Manual: `mkdir -p ~/.aidevops/langflow && cd ~/.aidevops/langflow && python3 -m venv venv && source venv/bin/activate && pip install langflow && langflow run`

Docker:

```bash
docker run -p 7860:7860 langflowai/langflow:latest
# Persistent storage:
docker run -p 7860:7860 -v langflow_data:/app/langflow langflowai/langflow:latest
```

Desktop app: <https://www.langflow.org/desktop> (Windows/macOS)

## Configuration

`~/.aidevops/langflow/.env` — set API keys via `aidevops secret` or edit directly:

```bash
LANGFLOW_HOST=0.0.0.0
LANGFLOW_PORT=7860
LANGFLOW_WORKERS=1
LANGFLOW_DATABASE_URL=sqlite:///./langflow.db
OPENAI_API_KEY=<your-key>
ANTHROPIC_API_KEY=<your-key>       # optional
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

localhost:7860 → New Flow → drag components, connect edges, configure → Run.

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

CrewAI: import in a custom component to define agents/tasks, connect to Langflow flow components.

## API & MCP Integration

```python
import requests
response = requests.post(
    "http://localhost:7860/api/v1/run/<flow-id>",
    json={"input_value": "Hello, world!", "output_type": "chat", "input_type": "chat"}
)
```

MCP server: `langflow run --mcp` or `LANGFLOW_MCP_ENABLED=true` in `.env`. Claude Code config:

```json
{ "mcpServers": { "langflow": { "command": "langflow", "args": ["run", "--mcp"] } } }
```

## Git Integration

```bash
langflow export --flow-id <flow-id> --output flows/my-flow.json  # single
langflow export --all --output flows/                             # all
langflow import --file flows/my-flow.json                         # restore
langflow import --directory flows/                                # bulk
# .gitignore: langflow.db, *.log, __pycache__/, .env
# Track: flows/*.json, components/*.py
```

## Local LLM Support

- **Ollama**: `curl -fsSL https://ollama.com/install.sh | sh && ollama pull llama3.2` — add Ollama component, set base URL `http://localhost:11434`
- **LM Studio**: <https://lmstudio.ai> — start local server, use OpenAI-compatible endpoint `http://localhost:1234/v1`

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
