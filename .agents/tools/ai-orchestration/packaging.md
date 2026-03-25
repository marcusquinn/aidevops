---
description: Packaging AI orchestration automations into deployable services
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

# Packaging AI Automations for Deployment

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Turn AI orchestration workflows into deployable services
- **Targets**: Web/SaaS, Desktop apps, Mobile backends, APIs
- **Principle**: Zero lock-in, standard Python dependencies, exportable

**Deployment Options**:

| Target | Technology | Best For |
|--------|------------|----------|
| Web API | FastAPI + Docker | SaaS, microservices |
| Desktop | PyInstaller | Offline tools |
| Mobile Backend | FastAPI + Cloud | App backends |
| Serverless | Vercel/AWS Lambda | Event-driven |

**Quick Commands**:

```bash
docker build -t my-agent-api .
pyinstaller --onefile main.py
vercel deploy
```

<!-- AI-CONTEXT-END -->

## Web/SaaS Deployment

### FastAPI Backend

```python
# api/main.py
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional

app = FastAPI(title="AI Agent API", version="1.0.0")

class AgentRequest(BaseModel):
    task: str
    context: Optional[dict] = None

class AgentResponse(BaseModel):
    result: str
    status: str

# CrewAI endpoint
@app.post("/crew/run", response_model=AgentResponse)
async def run_crew(request: AgentRequest):
    from crewai import Crew, Agent, Task
    try:
        agent = Agent(role="Assistant", goal="Complete the requested task", backstory="Helpful AI assistant.")
        task = Task(description=request.task, expected_output="Task completion result", agent=agent)
        crew = Crew(agents=[agent], tasks=[task])
        result = crew.kickoff()
        return AgentResponse(result=str(result), status="success")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# AutoGen endpoint
@app.post("/autogen/chat", response_model=AgentResponse)
async def autogen_chat(request: AgentRequest):
    from autogen_agentchat.agents import AssistantAgent
    from autogen_ext.models.openai import OpenAIChatCompletionClient
    try:
        model_client = OpenAIChatCompletionClient(model="gpt-4o-mini")
        agent = AssistantAgent("assistant", model_client=model_client)
        result = await agent.run(task=request.task)
        await model_client.close()
        return AgentResponse(result=str(result), status="success")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    return {"status": "healthy"}
```

### Docker Deployment

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**requirements.txt**:

```text
fastapi>=0.100.0
uvicorn>=0.23.0
crewai>=0.1.0
autogen-agentchat>=0.4.0
autogen-ext[openai]>=0.4.0
python-dotenv>=1.0.0
```

```yaml
# docker-compose.yml
services:
  agent-api:
    build: .
    ports:
      - "8000:8000"
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
    volumes:
      - ./data:/app/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

## Desktop Application

### PyInstaller Executable

```python
# desktop/main.py
import tkinter as tk
from tkinter import ttk, scrolledtext
import threading

class AgentApp:
    def __init__(self, root):
        self.root = root
        self.root.title("AI Agent Desktop")
        self.root.geometry("800x600")

        input_frame = ttk.Frame(root, padding="10")
        input_frame.pack(fill=tk.X)
        ttk.Label(input_frame, text="Task:").pack(side=tk.LEFT)
        self.task_entry = ttk.Entry(input_frame, width=60)
        self.task_entry.pack(side=tk.LEFT, padx=5)
        self.run_btn = ttk.Button(input_frame, text="Run", command=self.run_agent)
        self.run_btn.pack(side=tk.LEFT)

        self.output = scrolledtext.ScrolledText(root, height=30)
        self.output.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)

    def run_agent(self):
        task = self.task_entry.get()
        if not task:
            return
        self.run_btn.config(state=tk.DISABLED)
        self.output.insert(tk.END, f"\n> Running: {task}\n")
        threading.Thread(target=self._execute_agent, args=(task,)).start()

    def _execute_agent(self, task):
        try:
            from crewai import Crew, Agent, Task
            agent = Agent(role="Assistant", goal="Help with tasks", backstory="Helpful AI assistant")
            crew_task = Task(description=task, expected_output="Result", agent=agent)
            result = Crew(agents=[agent], tasks=[crew_task]).kickoff()
            self.root.after(0, lambda: self._show_result(str(result)))
        except Exception as e:
            self.root.after(0, lambda: self._show_result(f"Error: {e}"))

    def _show_result(self, result):
        self.output.insert(tk.END, f"\nResult:\n{result}\n")
        self.run_btn.config(state=tk.NORMAL)

if __name__ == "__main__":
    root = tk.Tk()
    AgentApp(root)
    root.mainloop()
```

```bash
pip install pyinstaller
pyinstaller --onefile --windowed desktop/main.py
# Output: dist/main.exe (Windows) or dist/main (macOS/Linux)
```

## Mobile Backend

### Async Task API

```python
# mobile_api/main.py
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel
import uuid

app = FastAPI()
tasks = {}  # Use Redis in production

class MobileRequest(BaseModel):
    task: str
    user_id: str

@app.post("/tasks/create")
async def create_task(request: MobileRequest, background_tasks: BackgroundTasks):
    task_id = str(uuid.uuid4())
    tasks[task_id] = {"status": "pending", "result": None}
    background_tasks.add_task(process_task, task_id, request.task)
    return {"task_id": task_id}

@app.get("/tasks/{task_id}")
async def get_task_status(task_id: str):
    if task_id not in tasks:
        raise HTTPException(status_code=404, detail="Task not found")
    return {"task_id": task_id, **tasks[task_id]}

async def process_task(task_id: str, task: str):
    tasks[task_id]["status"] = "processing"
    try:
        result = await run_agent(task)
        tasks[task_id].update({"result": result, "status": "completed"})
    except Exception as e:
        tasks[task_id].update({"result": str(e), "status": "failed"})
```

## Serverless Deployment

### Vercel Functions

```python
# api/agent.py
from http.server import BaseHTTPRequestHandler
import json

class handler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = json.loads(self.rfile.read(content_length))
        result = run_lightweight_agent(post_data.get('task', ''))
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'result': result}).encode())
```

### AWS Lambda

```python
def lambda_handler(event, context):
    body = json.loads(event.get('body', '{}'))
    result = run_agent(body.get('task', ''))
    return {'statusCode': 200, 'body': json.dumps({'result': result})}
```

## Export Patterns

```bash
# Langflow to standalone Python
langflow export --flow-id <id> --output my_flow.py
python my_flow.py

# CrewAI project export
crewai create crew my-project
cd my-project && pip freeze > requirements.txt
```

## CI/CD Integration

```yaml
# .github/workflows/deploy.yml
name: Deploy Agent API
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.11' }
      - run: pip install -r requirements.txt
      - run: pytest tests/
      - run: docker build -t agent-api .
      - run: |
          docker tag agent-api ${{ secrets.REGISTRY }}/agent-api:${{ github.sha }}
          docker push ${{ secrets.REGISTRY }}/agent-api:${{ github.sha }}
      - run: |
          kubectl set image deployment/agent-api \
            agent-api=${{ secrets.REGISTRY }}/agent-api:${{ github.sha }}
```

## Observability

```python
from opentelemetry import trace
from prometheus_client import Counter, Histogram

agent_requests = Counter('agent_requests_total', 'Total agent requests')
agent_latency = Histogram('agent_latency_seconds', 'Agent request latency')

@agent_latency.time()
async def run_agent_with_metrics(task):
    agent_requests.inc()
    return await run_agent(task)
```
