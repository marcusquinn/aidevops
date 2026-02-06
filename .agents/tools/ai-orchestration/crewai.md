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
- **License**: MIT (fully open-source, commercial use permitted)
- **Setup**: `bash .agent/scripts/crewai-helper.sh setup`
- **Start**: `~/.aidevops/scripts/start-crewai-studio.sh`
- **Stop**: `~/.aidevops/scripts/stop-crewai-studio.sh`
- **Status**: `~/.aidevops/scripts/crewai-status.sh`
- **URL**: http://localhost:8501 (CrewAI Studio)
- **Config**: `~/.aidevops/crewai/.env`
- **Install**: `pip install crewai` in venv at `~/.aidevops/crewai/venv/`

**Key Features**:

- Role-based autonomous agents
- Hierarchical task delegation
- YAML-based configuration
- Flows for event-driven control
- Sequential and parallel processes

<!-- AI-CONTEXT-END -->

## Overview

CrewAI is a lean, lightning-fast Python framework for orchestrating role-playing, autonomous AI agents. It empowers agents to work together seamlessly, tackling complex tasks through collaborative intelligence.

## Key Concepts

### Crews

Teams of AI agents with defined roles, goals, and backstories working together on tasks.

### Agents

Individual AI entities with:

- **Role**: Job title/function (e.g., "Senior Data Researcher")
- **Goal**: What the agent aims to achieve
- **Backstory**: Context that shapes behavior
- **Tools**: Capabilities the agent can use

### Tasks

Specific assignments with:

- **Description**: What needs to be done
- **Expected Output**: Format/content of results
- **Agent**: Who performs the task

### Flows

Event-driven workflows for precise control over complex automations.

## Installation

### Automated Setup (Recommended)

```bash
# Run the setup script
bash .agent/scripts/crewai-helper.sh setup

# Configure API keys
nano ~/.aidevops/crewai/.env

# Start CrewAI Studio
~/.aidevops/scripts/start-crewai-studio.sh
```

### Manual Installation

```bash
# Create directory and virtual environment
mkdir -p ~/.aidevops/crewai
cd ~/.aidevops/crewai
python3 -m venv venv
source venv/bin/activate

# Install CrewAI
pip install crewai

# Install with tools
pip install 'crewai[tools]'
```

### Create a New Project

```bash
# Create a new CrewAI project
crewai create crew my-project
cd my-project

# Install dependencies
crewai install

# Run the crew
crewai run
```

## Configuration

### Environment Variables

Create `~/.aidevops/crewai/.env`:

```bash
# OpenAI Configuration (Required)
OPENAI_API_KEY=your_openai_api_key_here

# Anthropic Configuration (Optional)
ANTHROPIC_API_KEY=your_anthropic_key_here

# Serper API for web search (Optional)
SERPER_API_KEY=your_serper_key_here

# Local LLM (Ollama)
OLLAMA_BASE_URL=http://localhost:11434

# CrewAI Configuration
CREWAI_TELEMETRY=false
```

### YAML Configuration

**agents.yaml**:

```yaml
researcher:
  role: >
    {topic} Senior Data Researcher
  goal: >
    Uncover cutting-edge developments in {topic}
  backstory: >
    You're a seasoned researcher with a knack for uncovering the latest
    developments in {topic}. Known for your ability to find the most relevant
    information and present it in a clear and concise manner.

analyst:
  role: >
    {topic} Reporting Analyst
  goal: >
    Create detailed reports based on {topic} data analysis
  backstory: >
    You're a meticulous analyst with a keen eye for detail. You're known for
    your ability to turn complex data into clear and concise reports.
```

**tasks.yaml**:

```yaml
research_task:
  description: >
    Conduct thorough research about {topic}.
    Make sure you find any interesting and relevant information.
  expected_output: >
    A list with 10 bullet points of the most relevant information about {topic}
  agent: researcher

reporting_task:
  description: >
    Review the context and expand each topic into a full section for a report.
  expected_output: >
    A fully fledged report with main topics, each with a full section.
    Formatted as markdown.
  agent: analyst
  output_file: report.md
```

## Usage

### Basic Crew Example

```python
from crewai import Agent, Crew, Process, Task

# Define agents
researcher = Agent(
    role="Senior Researcher",
    goal="Uncover groundbreaking technologies",
    backstory="You are an expert researcher with deep knowledge of AI.",
    verbose=True
)

writer = Agent(
    role="Tech Writer",
    goal="Create engaging content about technology",
    backstory="You are a skilled writer who makes complex topics accessible.",
    verbose=True
)

# Define tasks
research_task = Task(
    description="Research the latest AI developments",
    expected_output="A comprehensive summary of AI trends",
    agent=researcher
)

writing_task = Task(
    description="Write an article based on the research",
    expected_output="A well-written article about AI",
    agent=writer
)

# Create and run crew
crew = Crew(
    agents=[researcher, writer],
    tasks=[research_task, writing_task],
    process=Process.sequential,
    verbose=True
)

result = crew.kickoff(inputs={"topic": "AI Agents"})
print(result)
```

### Using Flows

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
        analyst = Agent(
            role="Market Analyst",
            goal="Analyze market data",
            backstory="Expert in market analysis"
        )
        
        task = Task(
            description="Analyze {sector} sector for {timeframe}",
            expected_output="Market analysis report",
            agent=analyst
        )
        
        crew = Crew(agents=[analyst], tasks=[task])
        return crew.kickoff(inputs=data)

    @router(analyze_with_crew)
    def route_result(self):
        if self.state.confidence > 0.8:
            return "high_confidence"
        return "low_confidence"

# Run the flow
flow = AnalysisFlow()
result = flow.kickoff()
```

### CrewAI Studio (GUI)

```bash
# Start CrewAI Studio
~/.aidevops/scripts/start-crewai-studio.sh

# Access at http://localhost:8501
```

## Local LLM Support

### Using Ollama

```python
from crewai import Agent, LLM

# Configure Ollama
llm = LLM(
    model="ollama/llama3.2",
    base_url="http://localhost:11434"
)

agent = Agent(
    role="Local AI Assistant",
    goal="Help with tasks using local LLM",
    backstory="You run entirely locally for privacy.",
    llm=llm
)
```

### Using LM Studio

```python
from crewai import LLM

llm = LLM(
    model="openai/local-model",
    base_url="http://localhost:1234/v1",
    api_key="not-needed"
)
```

## Git Integration

### Project Structure

```text
my-crew/
├── .gitignore
├── pyproject.toml
├── README.md
├── .env                    # gitignored
└── src/
    └── my_crew/
        ├── __init__.py
        ├── main.py
        ├── crew.py
        ├── tools/
        │   └── custom_tool.py
        └── config/
            ├── agents.yaml  # version controlled
            └── tasks.yaml   # version controlled
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
```

Track these files:

- `config/agents.yaml` - Agent definitions
- `config/tasks.yaml` - Task definitions
- `crew.py` - Crew orchestration logic
- `tools/*.py` - Custom tools

## Deployment

### Docker

```dockerfile
FROM python:3.11-slim

WORKDIR /app
COPY . .

RUN pip install crewai 'crewai[tools]'

CMD ["crewai", "run"]
```

### FastAPI Integration

```python
from fastapi import FastAPI
from crewai import Crew

app = FastAPI()

@app.post("/run-crew")
async def run_crew(topic: str):
    crew = create_my_crew()
    result = crew.kickoff(inputs={"topic": topic})
    return {"result": str(result)}
```

## Integration Examples

### With Langflow

Use CrewAI agents as custom components in Langflow flows.

### With aidevops Workflows

```bash
# Create a DevOps automation crew
crewai create crew devops-automation

# Configure agents for:
# - Code review
# - Documentation
# - Testing
# - Deployment
```

## Troubleshooting

### Common Issues

**Import errors**:

```bash
# Ensure crewai is installed
pip install crewai 'crewai[tools]'
```

**API key errors**:

```bash
# Check environment
echo $OPENAI_API_KEY

# Or use .env file
source .env
```

**Memory issues with multiple agents**:

```python
# Reduce verbosity
agent = Agent(..., verbose=False)

# Use smaller models
llm = LLM(model="gpt-4o-mini")
```

## Resources

- **Documentation**: https://docs.crewai.com
- **GitHub**: https://github.com/crewAIInc/crewAI
- **Community**: https://community.crewai.com
- **Examples**: https://github.com/crewAIInc/crewAI-examples
- **Courses**: https://learn.crewai.com
