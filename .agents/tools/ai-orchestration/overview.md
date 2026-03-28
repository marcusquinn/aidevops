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
bash .agents/scripts/langflow-helper.sh setup   # Langflow (visual flow builder)
bash .agents/scripts/crewai-helper.sh setup     # CrewAI (multi-agent teams)
bash .agents/scripts/autogen-helper.sh setup    # AutoGen (conversational agents)
bash .agents/scripts/agno-setup.sh setup        # Agno (enterprise agent OS)
git clone https://github.com/openprose/prose.git ~/.config/opencode/skill/open-prose  # OpenProse
```

**Port Allocation** (auto-managed via `localhost-helper.sh`):

| Tool | Default Port | Health Check | Port File |
|------|--------------|--------------|-----------|
| Langflow | 7860 | /health | /tmp/langflow_port |
| CrewAI Studio | 8501 | / | /tmp/crewai_studio_port |
| AutoGen Studio | 8081 | / | /tmp/autogen_studio_port |
| Agno | 7777 (API), 3000 (UI) | /health | - |

**Draft agents**: Orchestration tasks that discover reusable patterns should create draft agents in `~/.aidevops/agents/draft/`. These can be promoted to private (`custom/`) or shared (`.agents/`) after review. See `tools/build-agent/build-agent.md` "Agent Lifecycle Tiers".

<!-- AI-CONTEXT-END -->

## Decision Matrix

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

| Framework | Stars | GUI | Install | Run |
|-----------|-------|-----|---------|-----|
| Langflow | 143k+ | localhost:7860 | `pip install langflow` | `langflow run` |
| CrewAI | 42.5k+ | localhost:8501 (Studio) | `pip install crewai` | `crewai run` |
| AutoGen | 53.4k+ | AutoGen Studio | `pip install autogen-agentchat autogen-ext[openai]` | `autogenstudio ui` |
| Agno | - | localhost:3000 | `pip install "agno[all]"` | `~/.aidevops/scripts/start-agno-stack.sh` |
| OpenProse | 500+ | None (DSL) | `git clone https://github.com/openprose/prose.git ~/.config/opencode/skill/open-prose` | AI session = VM |

**OpenProse** is zero-dependency (pattern, not framework): explicit control flow (`parallel:`, `loop until`, `try/catch`), AI-evaluated conditions (`**the code is production ready**`), portable across Claude Code, OpenCode, Amp. Operates at the **workflow layer**, complementing DSPy (prompt optimization), TOON (context compression), and Context7/Augment (knowledge retrieval).

## Common Patterns

**Directory structure** (all tools):

```text
~/.aidevops/{tool}/
├── venv/           # Python virtual environment
├── .env            # API keys and configuration
├── .env.example    # Template
└── start_{tool}.sh # Startup script
```

- **Helper scripts**: `.agents/scripts/{tool}-helper.sh` — `setup | start | stop | status | check | help`
- **Config templates**: `configs/{tool}-config.json.txt` (committed); working: `configs/{tool}-config.json` (gitignored)
- **Management scripts**: `~/.aidevops/scripts/` — `start-{tool}-stack.sh`, `stop-{tool}-stack.sh`, `{tool}-status.sh`

## Integration with aidevops

**Git export formats**:

| Framework | Format | Location |
|-----------|--------|----------|
| Langflow | JSON flows | `flows/*.json` |
| CrewAI | YAML configs | `config/agents.yaml`, `config/tasks.yaml` |
| AutoGen | Python/JSON | `agents/*.py`, `*.json` |
| Agno | Python | `agent_os.py` |

**Langflow JSON sync**: `langflow export --flow-id <id> --output flows/my-flow.json` / `langflow import --file flows/my-flow.json`

**Local LLM (Ollama)**:

```bash
curl -fsSL https://ollama.com/install.sh | sh && ollama pull llama3.2
# In .env: OLLAMA_BASE_URL=http://localhost:11434
```

## Related Documentation

| Document | Purpose |
|----------|---------|
| `langflow.md` | Langflow setup and usage |
| `crewai.md` | CrewAI setup and usage |
| `autogen.md` | AutoGen setup and usage |
| `agno.md` | Agno setup and usage |
| `openprose.md` | OpenProse DSL for multi-agent orchestration |
| `packaging.md` | Web/SaaS (FastAPI+Docker+K8s), Desktop (PyInstaller), Mobile (RN/Flutter) |

## Troubleshooting

**Port conflicts** — all helpers auto-select alternatives via `localhost-helper.sh`:

```bash
~/.aidevops/scripts/localhost-helper.sh check-port 7860
~/.aidevops/scripts/localhost-helper.sh find-port 7860
~/.aidevops/scripts/localhost-helper.sh list-ports
~/.aidevops/scripts/localhost-helper.sh kill-port 7860
# Manual fallback: lsof -i :7860 && kill -9 $(lsof -t -i:7860)
```

**Venv issues**: `rm -rf ~/.aidevops/{tool}/venv && bash .agents/scripts/{tool}-helper.sh setup`

**API key errors**: `cat ~/.aidevops/{tool}/.env` or `env | grep -E "(OPENAI|ANTHROPIC|OLLAMA)"`
