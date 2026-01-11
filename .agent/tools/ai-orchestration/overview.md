---
description: AI orchestration framework comparison and selection guide
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# AI Orchestration Frameworks - Overview

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build and deploy AI-powered agents and multi-agent workflows
- **Frameworks**: Langflow, CrewAI, AutoGen, Agno, OpenProse
- **Common Pattern**: `~/.aidevops/{tool}/` with venv, .env, start scripts
- **All MIT Licensed**: Full commercial use permitted

**Quick Setup**:

```bash
# Langflow (visual flow builder)
bash .agent/scripts/langflow-helper.sh setup

# CrewAI (multi-agent teams)
bash .agent/scripts/crewai-helper.sh setup

# AutoGen (conversational agents)
bash .agent/scripts/autogen-helper.sh setup

# Agno (enterprise agent OS)
bash .agent/scripts/agno-setup.sh setup

# OpenProse (multi-agent DSL - no setup required, pattern-based)
git clone https://github.com/openprose/prose.git ~/.config/opencode/skill/open-prose
```

**Port Allocation** (auto-managed via `localhost-helper.sh`):

| Tool | Default Port | Health Check | Port File |
|------|--------------|--------------|-----------|
| Langflow | 7860 | /health | /tmp/langflow_port |
| CrewAI Studio | 8501 | / | /tmp/crewai_studio_port |
| AutoGen Studio | 8081 | / | /tmp/autogen_studio_port |
| Agno | 7777 (API), 3000 (UI) | /health | - |

**Port Conflict Resolution**: All helper scripts integrate with `localhost-helper.sh` for automatic port management. If a port is in use, an alternative is automatically selected.

<!-- AI-CONTEXT-END -->

## Decision Matrix

Use this matrix to select the right framework for your use case:

| Objective | Recommended | Why | Alternatives |
|-----------|-------------|-----|--------------|
| **Rapid Prototyping (Visual)** | Langflow | Drag-and-drop GUI, exports to code, MCP server support | CrewAI Studio |
| **Multi-Agent Teams** | CrewAI | Hierarchical roles/tasks, sequential/parallel orchestration | AutoGen |
| **Conversational/Iterative** | AutoGen | Group chats, human-in-loop, code execution | CrewAI Flows |
| **Complex Orchestration** | Langflow | Stateful workflows, branching, LangGraph integration | CrewAI Flows |
| **Enterprise Agent OS** | Agno | Production-ready runtime, specialized DevOps agents | - |
| **Code-First Development** | CrewAI | YAML configs, Python decorators, minimal boilerplate | AutoGen |
| **Microsoft Ecosystem** | AutoGen | .NET support, Azure integration | - |
| **Multi-Agent DSL** | OpenProse | Explicit control flow, AI-evaluated conditions, zero dependencies | CrewAI Flows |
| **Loop Orchestration** | OpenProse | `loop until **condition**`, parallel blocks, retry semantics | Ralph Loop |
| **Local LLM Priority** | All | All support Ollama/local models | - |

## Framework Comparison

### Langflow

**Best for**: Visual prototyping, RAG pipelines, quick iterations

- **License**: MIT
- **Stars**: 143k+
- **GUI**: Native web UI (localhost:7860)
- **Install**: `pip install langflow`
- **Run**: `langflow run`

**Strengths**:

- Drag-and-drop visual flow builder
- Exports flows to Python code
- Built-in MCP server support
- LangChain ecosystem integration
- Desktop app available

**Use Cases**:

- RAG applications
- Chatbot prototypes
- API workflow automation
- Visual debugging of agent flows

### CrewAI

**Best for**: Role-based multi-agent teams, production workflows

- **License**: MIT
- **Stars**: 42.5k+
- **GUI**: CrewAI Studio (Streamlit-based)
- **Install**: `pip install crewai`
- **Run**: `crewai run`

**Strengths**:

- Role-playing autonomous agents
- Hierarchical task delegation
- YAML-based configuration
- Flows for event-driven control
- Strong community (100k+ certified developers)

**Use Cases**:

- Content generation teams
- Research automation
- Sales/marketing workflows
- Code review pipelines

### AutoGen

**Best for**: Conversational agents, research tasks, Microsoft integration

- **License**: MIT (code) / CC-BY-4.0 (docs)
- **Stars**: 53.4k+
- **GUI**: AutoGen Studio
- **Install**: `pip install autogen-agentchat autogen-ext[openai]`
- **Run**: `autogenstudio ui`

**Strengths**:

- Multi-language support (Python, .NET)
- MCP server integration
- Human-in-the-loop workflows
- AgentChat for rapid prototyping
- Core API for advanced control

**Use Cases**:

- Code generation/review
- Research assistants
- Interactive debugging
- Enterprise .NET integration

### Agno

**Best for**: Enterprise DevOps, production agent runtime

- **License**: MIT
- **GUI**: Agent-UI (localhost:3000)
- **Install**: `pip install "agno[all]"`
- **Run**: `~/.aidevops/scripts/start-agno-stack.sh`

**Strengths**:

- Complete local processing (privacy)
- Specialized DevOps agents
- Knowledge base support
- Production-ready runtime

**Use Cases**:

- Infrastructure automation
- Code review workflows
- Documentation generation
- DevOps task automation

### OpenProse

**Best for**: Multi-agent orchestration DSL, explicit control flow, loop agents

- **License**: MIT
- **Stars**: 500+
- **GUI**: None (DSL executed by AI session)
- **Install**: `git clone https://github.com/openprose/prose.git ~/.config/opencode/skill/open-prose`
- **Run**: AI session becomes the VM

**Strengths**:

- Zero dependencies (pattern, not framework)
- Explicit control flow (`parallel:`, `loop until`, `try/catch`)
- AI-evaluated conditions (`**the code is production ready**`)
- Portable across Claude Code, OpenCode, Amp
- Complements DSPy, TOON, Context7

**Use Cases**:

- Multi-agent parallel workflows
- Iterative development loops (Ralph-style)
- Complex conditional orchestration
- Reusable workflow templates

**Relationship to Other Tools**:

OpenProse operates at the **workflow layer**, complementing:
- **DSPy**: Prompt optimization (can use DSPy-compiled prompts in agents)
- **TOON**: Data compression (can TOON-encode context between sessions)
- **Context7/Augment**: Knowledge retrieval (sessions can call these tools)

## Common Design Patterns

All AI orchestration tools in aidevops follow these patterns:

### Directory Structure

```text
~/.aidevops/{tool}/
├── venv/                 # Python virtual environment
├── .env                  # API keys and configuration
├── .env.example          # Template for .env
├── start_{tool}.sh       # Startup script
└── {tool-specific}/      # Tool-specific files
```

### Helper Script Pattern

Each tool has a helper script at `.agent/scripts/{tool}-helper.sh` with:

```bash
# Standard commands
setup     # Install and configure
start     # Start services
stop      # Stop services
status    # Check health
check     # Verify prerequisites
help      # Show usage
```

### Configuration Template

Each tool has a config template at `configs/{tool}-config.json.txt` with:

- Default ports and URLs
- Agent definitions
- Model configuration
- Security settings
- Integration options

### Management Scripts

After setup, management scripts are created at `~/.aidevops/scripts/`:

- `start-{tool}-stack.sh` - Start all services
- `stop-{tool}-stack.sh` - Stop all services
- `{tool}-status.sh` - Check service health

## Integration with aidevops

### Git Version Control

All frameworks support exporting configurations for Git:

| Framework | Export Format | Location |
|-----------|---------------|----------|
| Langflow | JSON flows | `flows/*.json` |
| CrewAI | YAML configs | `config/agents.yaml`, `config/tasks.yaml` |
| AutoGen | Python/JSON | `agents/*.py`, `*.json` |
| Agno | Python | `agent_os.py` |

### Bi-directional Sync

For Langflow, use the JSON bridge pattern:

```bash
# Export flow to JSON
langflow export --flow-id <id> --output flows/my-flow.json

# Import JSON to Langflow
langflow import --file flows/my-flow.json
```

### Local LLM Support

All frameworks support Ollama for local LLMs:

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model
ollama pull llama3.2

# Configure in .env
OLLAMA_BASE_URL=http://localhost:11434
```

## Packaging for Production

See `packaging.md` for detailed deployment guides:

- **Web/SaaS**: FastAPI + Docker + Kubernetes
- **Desktop**: PyInstaller executables
- **Mobile**: React Native/Flutter wrappers

## Related Documentation

| Document | Purpose |
|----------|---------|
| `langflow.md` | Langflow setup and usage |
| `crewai.md` | CrewAI setup and usage |
| `autogen.md` | AutoGen setup and usage |
| `agno.md` | Agno setup and usage |
| `openprose.md` | OpenProse DSL for multi-agent orchestration |
| `packaging.md` | Deployment and packaging |

## Troubleshooting

### Common Issues

**Port conflicts**:

All AI orchestration helper scripts integrate with `localhost-helper.sh` for automatic port management. If a default port is in use, an alternative is automatically selected and saved to `/tmp/{tool}_port`.

```bash
# Check port availability (uses localhost-helper.sh if available)
~/.aidevops/scripts/localhost-helper.sh check-port 7860

# Find next available port
~/.aidevops/scripts/localhost-helper.sh find-port 7860

# List all dev ports in use
~/.aidevops/scripts/localhost-helper.sh list-ports

# Kill process on port
~/.aidevops/scripts/localhost-helper.sh kill-port 7860

# Manual fallback
lsof -i :7860
kill -9 $(lsof -t -i:7860)
```

**Virtual environment issues**:

```bash
# Recreate venv
rm -rf ~/.aidevops/{tool}/venv
bash .agent/scripts/{tool}-helper.sh setup
```

**API key errors**:

```bash
# Verify .env file
cat ~/.aidevops/{tool}/.env

# Check environment
env | grep -E "(OPENAI|ANTHROPIC|OLLAMA)"
```

### Getting Help

- Langflow: https://github.com/langflow-ai/langflow/discussions
- CrewAI: https://community.crewai.com
- AutoGen: https://github.com/microsoft/autogen/discussions
- Agno: https://github.com/agno-ai/agno/discussions
- OpenProse: https://github.com/openprose/prose/issues
