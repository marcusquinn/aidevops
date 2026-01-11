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
# Build Docker image
docker build -t my-agent-api .

# Create executable
pyinstaller --onefile main.py

# Deploy to Vercel
vercel deploy
```

<!-- AI-CONTEXT-END -->

## Overview

This guide covers packaging AI orchestration automations (Langflow, CrewAI, AutoGen, Agno) into production-ready services. The focus is on zero lock-in approaches using standard Python dependencies.

## Web/SaaS Deployment

### FastAPI Backend

Create a REST API for your AI agents:

```python
# api/main.py
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional
import asyncio

app = FastAPI(
    title="AI Agent API",
    description="AI DevOps Framework - Agent Service",
    version="1.0.0"
)

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
        agent = Agent(
            role="Assistant",
            goal="Complete the requested task",
            backstory="You are a helpful AI assistant."
        )
        
        task = Task(
            description=request.task,
            expected_output="Task completion result",
            agent=agent
        )
        
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

# Health check
@app.get("/health")
async def health_check():
    return {"status": "healthy"}
```

### Docker Deployment

```dockerfile
# Dockerfile
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY . .

# Expose port
EXPOSE 8000

# Run with uvicorn
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

### Docker Compose

```yaml
# docker-compose.yml
version: '3.8'

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

  # Optional: Redis for caching
  redis:
    image: redis:alpine
    ports:
      - "6379:6379"
```

### Kubernetes Deployment

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: agent-api
  template:
    metadata:
      labels:
        app: agent-api
    spec:
      containers:
      - name: agent-api
        image: your-registry/agent-api:latest
        ports:
        - containerPort: 8000
        env:
        - name: OPENAI_API_KEY
          valueFrom:
            secretKeyRef:
              name: api-secrets
              key: openai-key
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
---
apiVersion: v1
kind: Service
metadata:
  name: agent-api-service
spec:
  selector:
    app: agent-api
  ports:
  - port: 80
    targetPort: 8000
  type: LoadBalancer
```

### SaaS Boilerplate

Add authentication and billing:

```python
# api/auth.py
from fastapi import Depends, HTTPException, Security
from fastapi.security import APIKeyHeader
import stripe

api_key_header = APIKeyHeader(name="X-API-Key")

async def verify_api_key(api_key: str = Security(api_key_header)):
    # Verify API key against database
    if not is_valid_key(api_key):
        raise HTTPException(status_code=403, detail="Invalid API key")
    return api_key

# api/billing.py
stripe.api_key = os.getenv("STRIPE_SECRET_KEY")

def create_usage_record(customer_id: str, quantity: int):
    """Record API usage for billing"""
    stripe.SubscriptionItem.create_usage_record(
        subscription_item_id=get_subscription_item(customer_id),
        quantity=quantity,
        timestamp=int(time.time())
    )
```

## Desktop Application

### PyInstaller Executable

```python
# desktop/main.py
import sys
import tkinter as tk
from tkinter import ttk, scrolledtext
import threading

class AgentApp:
    def __init__(self, root):
        self.root = root
        self.root.title("AI Agent Desktop")
        self.root.geometry("800x600")
        
        # Input frame
        input_frame = ttk.Frame(root, padding="10")
        input_frame.pack(fill=tk.X)
        
        ttk.Label(input_frame, text="Task:").pack(side=tk.LEFT)
        self.task_entry = ttk.Entry(input_frame, width=60)
        self.task_entry.pack(side=tk.LEFT, padx=5)
        
        self.run_btn = ttk.Button(input_frame, text="Run", command=self.run_agent)
        self.run_btn.pack(side=tk.LEFT)
        
        # Output area
        self.output = scrolledtext.ScrolledText(root, height=30)
        self.output.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
    
    def run_agent(self):
        task = self.task_entry.get()
        if not task:
            return
        
        self.run_btn.config(state=tk.DISABLED)
        self.output.insert(tk.END, f"\n> Running: {task}\n")
        
        # Run in background thread
        thread = threading.Thread(target=self._execute_agent, args=(task,))
        thread.start()
    
    def _execute_agent(self, task):
        try:
            from crewai import Crew, Agent, Task
            
            agent = Agent(
                role="Assistant",
                goal="Help with tasks",
                backstory="Helpful AI assistant"
            )
            
            crew_task = Task(
                description=task,
                expected_output="Result",
                agent=agent
            )
            
            crew = Crew(agents=[agent], tasks=[crew_task])
            result = crew.kickoff()
            
            self.root.after(0, lambda: self._show_result(str(result)))
        except Exception as e:
            self.root.after(0, lambda: self._show_result(f"Error: {e}"))
    
    def _show_result(self, result):
        self.output.insert(tk.END, f"\nResult:\n{result}\n")
        self.run_btn.config(state=tk.NORMAL)

if __name__ == "__main__":
    root = tk.Tk()
    app = AgentApp(root)
    root.mainloop()
```

**Build executable**:

```bash
# Install PyInstaller
pip install pyinstaller

# Build single executable
pyinstaller --onefile --windowed desktop/main.py

# Output in dist/main.exe (Windows) or dist/main (macOS/Linux)
```

### Electron Wrapper

For a more polished desktop experience:

```javascript
// electron/main.js
const { app, BrowserWindow } = require('electron');
const { spawn } = require('child_process');
const path = require('path');

let mainWindow;
let pythonProcess;

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1200,
        height: 800,
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false
        }
    });

    // Start Python backend
    pythonProcess = spawn('python', [
        path.join(__dirname, 'backend', 'server.py')
    ]);

    // Load frontend
    mainWindow.loadFile('index.html');
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
    if (pythonProcess) pythonProcess.kill();
    if (process.platform !== 'darwin') app.quit();
});
```

## Mobile Backend

### API for Mobile Apps

```python
# mobile_api/main.py
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel
import uuid

app = FastAPI()

# In-memory task storage (use Redis in production)
tasks = {}

class MobileRequest(BaseModel):
    task: str
    user_id: str

class TaskStatus(BaseModel):
    task_id: str
    status: str
    result: str = None

@app.post("/tasks/create")
async def create_task(request: MobileRequest, background_tasks: BackgroundTasks):
    task_id = str(uuid.uuid4())
    tasks[task_id] = {"status": "pending", "result": None}
    
    # Run in background
    background_tasks.add_task(process_task, task_id, request.task)
    
    return {"task_id": task_id}

@app.get("/tasks/{task_id}", response_model=TaskStatus)
async def get_task_status(task_id: str):
    if task_id not in tasks:
        raise HTTPException(status_code=404, detail="Task not found")
    
    return TaskStatus(
        task_id=task_id,
        status=tasks[task_id]["status"],
        result=tasks[task_id]["result"]
    )

async def process_task(task_id: str, task: str):
    tasks[task_id]["status"] = "processing"
    
    try:
        # Run your agent here
        result = await run_agent(task)
        tasks[task_id]["result"] = result
        tasks[task_id]["status"] = "completed"
    except Exception as e:
        tasks[task_id]["result"] = str(e)
        tasks[task_id]["status"] = "failed"
```

### React Native Integration

```javascript
// mobile/AgentService.js
const API_URL = 'https://your-api.com';

export async function createTask(task, userId) {
    const response = await fetch(`${API_URL}/tasks/create`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${getToken()}`
        },
        body: JSON.stringify({ task, user_id: userId })
    });
    return response.json();
}

export async function pollTaskStatus(taskId) {
    const response = await fetch(`${API_URL}/tasks/${taskId}`);
    return response.json();
}
```

## Serverless Deployment

### Vercel Functions

```python
# api/agent.py (Vercel serverless function)
from http.server import BaseHTTPRequestHandler
import json

class handler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = json.loads(self.rfile.read(content_length))
        
        task = post_data.get('task', '')
        
        # Run agent (keep it lightweight for serverless)
        result = run_lightweight_agent(task)
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'result': result}).encode())
```

### AWS Lambda

```python
# lambda_function.py
import json

def lambda_handler(event, context):
    body = json.loads(event.get('body', '{}'))
    task = body.get('task', '')
    
    # Run agent
    result = run_agent(task)
    
    return {
        'statusCode': 200,
        'body': json.dumps({'result': result})
    }
```

## Export Patterns

### Langflow to Standalone

```bash
# Export flow to Python
langflow export --flow-id <id> --output my_flow.py

# The exported file can run independently
python my_flow.py
```

### CrewAI Project Export

```bash
# Create standalone project
crewai create crew my-project

# Package for distribution
cd my-project
pip freeze > requirements.txt
```

### AutoGen Workflow Export

```python
# Save workflow configuration
import json

workflow_config = {
    "agents": [
        {"name": "researcher", "role": "Research specialist"},
        {"name": "writer", "role": "Content writer"}
    ],
    "tasks": [
        {"description": "Research topic", "agent": "researcher"},
        {"description": "Write report", "agent": "writer"}
    ]
}

with open("workflow.json", "w") as f:
    json.dump(workflow_config, f, indent=2)
```

## CI/CD Integration

### GitHub Actions

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
      
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      
      - name: Install dependencies
        run: pip install -r requirements.txt
      
      - name: Run tests
        run: pytest tests/
      
      - name: Build Docker image
        run: docker build -t agent-api .
      
      - name: Push to registry
        run: |
          docker tag agent-api ${{ secrets.REGISTRY }}/agent-api:${{ github.sha }}
          docker push ${{ secrets.REGISTRY }}/agent-api:${{ github.sha }}
      
      - name: Deploy to Kubernetes
        run: |
          kubectl set image deployment/agent-api \
            agent-api=${{ secrets.REGISTRY }}/agent-api:${{ github.sha }}
```

## Best Practices

### Zero Lock-in

1. Use standard Python dependencies
2. Export configurations to JSON/YAML
3. Avoid proprietary formats
4. Document all external dependencies

### Security

1. Never hardcode API keys
2. Use environment variables or secret managers
3. Implement rate limiting
4. Add authentication for production APIs

### Performance

1. Use async/await for I/O operations
2. Implement caching where appropriate
3. Consider connection pooling for databases
4. Monitor memory usage with multiple agents

### Monitoring

```python
# Add observability
from opentelemetry import trace
from prometheus_client import Counter, Histogram

agent_requests = Counter('agent_requests_total', 'Total agent requests')
agent_latency = Histogram('agent_latency_seconds', 'Agent request latency')

@agent_latency.time()
async def run_agent_with_metrics(task):
    agent_requests.inc()
    return await run_agent(task)
```
