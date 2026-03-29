---
description: Agno multi-modal AI agent framework
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

# Agno Integration for AI DevOps Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Setup:** `bash .agents/scripts/agno-setup.sh setup` (one-time)
- **Start/Stop/Status:** `start-agno-stack.sh` / `stop-agno-stack.sh` / `agno-status.sh` (in `~/.aidevops/scripts/`)
- **URLs:** Agent-UI http://localhost:3000 · AgentOS API http://localhost:8000 · Docs /docs
- **Config:** `~/.aidevops/agno/.env` — `OPENAI_API_KEY` required
- **Agents:** DevOps Assistant, Code Review Assistant, Documentation Assistant
- **Requirements:** Python 3.8+, Node.js 18+
- **Privacy:** Complete local processing, zero external data transmission

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Recommended
bash .agents/scripts/agno-setup.sh setup

# Manual: AgentOS
mkdir -p ~/.aidevops/agno && cd ~/.aidevops/agno
python3 -m venv venv && source venv/bin/activate
pip install "agno[all]"

# Manual: Agent-UI
mkdir -p ~/.aidevops/agent-ui && cd ~/.aidevops/agent-ui
npx create-agent-ui@latest . --yes
```

## Configuration

`~/.aidevops/agno/.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here
AGNO_PORT=8000
AGNO_DEBUG=true
# Optional
ANTHROPIC_API_KEY=your_anthropic_key_here
GOOGLE_API_KEY=your_google_key_here
GROQ_API_KEY=your_groq_key_here
```

`~/.aidevops/agent-ui/.env.local`:

```bash
NEXT_PUBLIC_AGNO_API_URL=http://localhost:8000
NEXT_PUBLIC_APP_NAME=AI DevOps Assistant
PORT=3000
```

## Service Commands

| Command | Purpose |
|---------|---------|
| `agno-setup.sh setup` | One-time setup |
| `agno-setup.sh check` | Check prerequisites |
| `agno-setup.sh agno` | AgentOS only |
| `agno-setup.sh ui` | Agent-UI only |
| `start-agno-stack.sh` | Start both services |
| `stop-agno-stack.sh` | Stop services |
| `agno-status.sh` | Check status |

Update: `cd ~/.aidevops/agno && source venv/bin/activate && pip install --upgrade "agno[all]"` · `cd ~/.aidevops/agent-ui && npm update`

## Available Agents

| Agent | Specialization | Tools |
|-------|---------------|-------|
| DevOps Assistant | Infrastructure automation, CI/CD, cloud, security, monitoring | Web search, file ops, shell (safe), Python (safe) |
| Code Review Assistant | Quality analysis, security vulnerabilities, performance, testing | File ops, Python analysis |
| Documentation Assistant | API docs, architecture, READMEs, runbooks | File ops, web search, doc generation |

## API Integration

```python
import requests

response = requests.post(
    "http://localhost:8000/v1/agents/devops-assistant/chat",
    json={"message": "Help me optimize our CI/CD pipeline", "stream": False}
)
print(response.json())
```

## Custom Agents

Add to `~/.aidevops/agno/agent_os.py`:

```python
security_agent = Agent(
    name="Security Audit Assistant",
    model=model,
    tools=[FileTools(), ShellTools(run_code=False)],
    instructions=[
        "Security vulnerability assessment",
        "Compliance checking and reporting",
        "Threat modeling and risk assessment"
    ]
)

agent_os = AgentOS(
    agents=[devops_agent, code_review_agent, docs_agent, security_agent]
)
```

## Advanced Configuration

**Persistent storage:**

```python
from agno.storage.postgres import PostgresDb
storage = PostgresDb(host="localhost", port=5432, user="agno_user",
                     password="agno_password", database="agno_db")
devops_agent.storage = storage
```

**Knowledge base:**

```python
from agno.knowledge.pdf import PDFKnowledgeBase
kb = PDFKnowledgeBase(path="./documentation", vector_db=ChromaDb())
devops_agent.knowledge_base = kb
```

## Troubleshooting

**Port conflicts:**

```bash
lsof -i :8000  # AgentOS
lsof -i :3000  # Agent-UI
export AGNO_PORT=8001 && export AGENT_UI_PORT=3001
```

**API key not set:**

```bash
cd ~/.aidevops/agno && source venv/bin/activate
python -c "import os; print('OPENAI_API_KEY:', 'SET' if os.getenv('OPENAI_API_KEY') else 'NOT SET')"
```

**Permission issues:**

```bash
chmod +x ~/.aidevops/scripts/*.sh
chmod +x ~/.aidevops/agno/start_agno.sh
chmod +x ~/.aidevops/agent-ui/start_agent_ui.sh
```

**Performance — faster model config:**

```python
model = OpenAIChat(model="gpt-4o-mini", temperature=0.1, max_tokens=2000, timeout=30)
```
