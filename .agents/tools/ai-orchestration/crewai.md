---
description: CrewAI multi-agent orchestration - setup, usage, and integration
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

# CrewAI - Multi-Agent Orchestration Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Role-playing autonomous AI agents working as teams
- **License**: MIT (commercial use permitted)
- **Setup**: `bash .agents/scripts/crewai-helper.sh setup`
- **Start/Stop/Status**: `~/.aidevops/scripts/start-crewai-studio.sh` / `stop-crewai-studio.sh` / `crewai-status.sh`
- **URL**: http://localhost:8501 (CrewAI Studio)
- **Config**: `~/.aidevops/crewai/.env`
- **Install**: `pip install crewai 'crewai[tools]'` in venv at `~/.aidevops/crewai/venv/`

**Core concepts**: Crew (team) → Agent (role+goal+backstory+tools) → Task (description+expected_output+agent) → Flow (event-driven control)

<!-- AI-CONTEXT-END -->

## Installation

```bash
# Automated (recommended)
bash .agents/scripts/crewai-helper.sh setup
nano ~/.aidevops/crewai/.env
~/.aidevops/scripts/start-crewai-studio.sh

# Manual
mkdir -p ~/.aidevops/crewai && cd ~/.aidevops/crewai
python3 -m venv venv && source venv/bin/activate
pip install crewai 'crewai[tools]'

# New project
crewai create crew my-project && cd my-project
crewai install && crewai run
```

## Configuration

`~/.aidevops/crewai/.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_key_here   # optional
SERPER_API_KEY=your_serper_key_here          # optional, web search
OLLAMA_BASE_URL=http://localhost:11434        # optional, local LLM
CREWAI_TELEMETRY=false
```

**agents.yaml**:

```yaml
researcher:
  role: "{topic} Senior Data Researcher"
  goal: "Uncover cutting-edge developments in {topic}"
  backstory: "Seasoned researcher known for finding relevant information clearly."

analyst:
  role: "{topic} Reporting Analyst"
  goal: "Create detailed reports based on {topic} data analysis"
  backstory: "Meticulous analyst who turns complex data into clear reports."
```

**tasks.yaml**:

```yaml
research_task:
  description: "Conduct thorough research about {topic}."
  expected_output: "10 bullet points of the most relevant information about {topic}"
  agent: researcher

reporting_task:
  description: "Expand each research topic into a full report section."
  expected_output: "Fully fledged markdown report with main topics."
  agent: analyst
  output_file: report.md
```

## Usage

### Basic Crew

```python
from crewai import Agent, Crew, Process, Task

researcher = Agent(
    role="Senior Researcher",
    goal="Uncover groundbreaking technologies",
    backstory="Expert researcher with deep knowledge of AI.",
    verbose=True
)
writer = Agent(
    role="Tech Writer",
    goal="Create engaging content about technology",
    backstory="Skilled writer who makes complex topics accessible.",
    verbose=True
)

crew = Crew(
    agents=[researcher, writer],
    tasks=[
        Task(description="Research latest AI developments",
             expected_output="Summary of AI trends", agent=researcher),
        Task(description="Write article based on research",
             expected_output="Well-written AI article", agent=writer),
    ],
    process=Process.sequential,
    verbose=True
)
result = crew.kickoff(inputs={"topic": "AI Agents"})
```

### Flows (Event-Driven)

```python
from crewai.flow.flow import Flow, listen, start, router
from crewai import Crew, Agent, Task
from pydantic import BaseModel

class MarketState(BaseModel):
    sentiment: str = "neutral"
    confidence: float = 0.0

class AnalysisFlow(Flow[MarketState]):
    @start()
    def fetch_data(self):
        return {"sector": "tech", "timeframe": "1W"}

    @listen(fetch_data)
    def analyze_with_crew(self, data):
        analyst = Agent(role="Market Analyst", goal="Analyze market data",
                        backstory="Expert in market analysis")
        task = Task(description="Analyze {sector} sector for {timeframe}",
                    expected_output="Market analysis report", agent=analyst)
        return Crew(agents=[analyst], tasks=[task]).kickoff(inputs=data)

    @router(analyze_with_crew)
    def route_result(self):
        return "high_confidence" if self.state.confidence > 0.8 else "low_confidence"

flow = AnalysisFlow()
result = flow.kickoff()
```

## Local LLM Support

```python
from crewai import Agent, LLM

# Ollama
llm = LLM(model="ollama/llama3.2", base_url="http://localhost:11434")

# LM Studio
llm = LLM(model="openai/local-model", base_url="http://localhost:1234/v1", api_key="not-needed")

agent = Agent(role="Local AI Assistant", goal="Help with tasks",
              backstory="Runs entirely locally for privacy.", llm=llm)
```

## Deployment

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY . .
RUN pip install crewai 'crewai[tools]'
CMD ["crewai", "run"]
```

```python
# FastAPI
from fastapi import FastAPI
from crewai import Crew

app = FastAPI()

@app.post("/run-crew")
async def run_crew(topic: str):
    result = create_my_crew().kickoff(inputs={"topic": topic})
    return {"result": str(result)}
```

## Project Structure

```text
my-crew/
├── .env                    # gitignored
├── src/my_crew/
│   ├── crew.py
│   ├── main.py
│   ├── tools/custom_tool.py
│   └── config/
│       ├── agents.yaml     # version controlled
│       └── tasks.yaml      # version controlled
```

`.gitignore`: `.env`, `__pycache__/`, `*.pyc`, `.venv/`, `venv/`, `*.log`

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Import errors | `pip install crewai 'crewai[tools]'` |
| API key errors | `echo $OPENAI_API_KEY` or `source .env` |
| Memory issues | `Agent(..., verbose=False)` or `LLM(model="gpt-4o-mini")` |

## Resources

- **Docs**: https://docs.crewai.com
- **GitHub**: https://github.com/crewAIInc/crewAI
- **Examples**: https://github.com/crewAIInc/crewAI-examples
- **Community**: https://community.crewai.com
- **Courses**: https://learn.crewai.com
