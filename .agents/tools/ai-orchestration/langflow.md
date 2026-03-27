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
- **Setup**: `bash .agents/scripts/langflow-helper.sh setup`
- **Start/Stop/Status**: `~/.aidevops/scripts/start-langflow.sh` / `stop-langflow.sh` / `langflow-status.sh`
- **URL**: http://localhost:7860 | **API Docs**: http://localhost:7860/docs | **Health**: http://localhost:7860/health
- **Config**: `~/.aidevops/langflow/.env`
- **Install**: `pip install langflow` in venv at `~/.aidevops/langflow/venv/`
- **Privacy**: Flows stored locally, optional cloud sync

**Key Features**: Drag-and-drop flow builder, Python code export, MCP server support, LangChain integration, local LLM (Ollama)

<!-- AI-CONTEXT-END -->

## Installation

**Automated (recommended):**

```bash
bash .agents/scripts/langflow-helper.sh setup
nano ~/.aidevops/langflow/.env
~/.aidevops/scripts/start-langflow.sh
```

**Manual:**

```bash
mkdir -p ~/.aidevops/langflow && cd ~/.aidevops/langflow
python3 -m venv venv && source venv/bin/activate
pip install langflow && langflow run
```

**Docker:**

```bash
docker run -p 7860:7860 langflowai/langflow:latest
docker run -p 7860:7860 -v langflow_data:/app/langflow langflowai/langflow:latest  # persistent
```

Desktop app: https://www.langflow.org/desktop (Windows/macOS)

## Configuration

**`~/.aidevops/langflow/.env`:**

```bash
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_key_here   # optional
LANGFLOW_HOST=0.0.0.0
LANGFLOW_PORT=7860
LANGFLOW_WORKERS=1
LANGFLOW_DATABASE_URL=sqlite:///./langflow.db
OLLAMA_BASE_URL=http://localhost:11434
```

**Custom components** (`~/.aidevops/langflow/components/my_component.py`):

```python
from langflow.custom import CustomComponent
from langflow.schema import Data

class MyCustomComponent(CustomComponent):
    display_name = "My Custom Component"
    description = "A custom component for aidevops"

    def build(self, input_text: str) -> Data:
        return Data(text=input_text.upper())
```

Load: `langflow run --components-path ~/.aidevops/langflow/components/`

## Usage

Open http://localhost:7860 → "New Flow" or template → drag components from sidebar, connect edges, configure parameters → "Run".

**RAG Pipeline:**

```text
[Document Loader] → [Text Splitter] → [Embeddings] → [Vector Store]
                                                           ↓
[User Input] → [Retriever] → [LLM] → [Output]
```

**Multi-Agent Chat:**

```text
[User Input] → [Router Agent] → [Specialist Agent 1]
                             → [Specialist Agent 2]
                             → [Aggregator] → [Output]
```

## API Integration

**REST API:**

```python
import requests
response = requests.post(
    "http://localhost:7860/api/v1/run/<flow-id>",
    json={"input_value": "Hello, world!", "output_type": "chat", "input_type": "chat"}
)
print(response.json())
```

**MCP Server:**

```bash
langflow run --mcp
# Or in .env: LANGFLOW_MCP_ENABLED=true
```

Connect from any MCP-compatible AI assistant. Claude Code config:

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

Bi-directional sync: use `watchdog` file watcher to auto-import on `.json` changes.

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

**Production**: PostgreSQL (not SQLite), enable auth for multi-user, reverse proxy (nginx/traefik) for HTTPS.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Port in use | `lsof -i :7860` → `kill -9 <PID>` |
| Database errors | `rm ~/.aidevops/langflow/langflow.db && langflow run` |
| Component not loading | `python -c "from components.my_component import MyCustomComponent"` |
| Debug logs | `LANGFLOW_LOG_LEVEL=DEBUG langflow run` or `tail -f ~/.aidevops/langflow/langflow.log` |

## Integrations

- **CrewAI**: Custom component importing CrewAI, define agents/tasks, connect to Langflow components
- **aidevops workflows**: `langflow export --flow-id <id> --output flows/devops-automation.json` then commit to git

## Resources

- **Docs**: https://docs.langflow.org
- **GitHub**: https://github.com/langflow-ai/langflow
- **Discord**: https://discord.gg/EqksyE2EX9
- **Templates**: https://www.langflow.org/templates
