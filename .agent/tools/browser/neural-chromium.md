---
description: Neural-Chromium - agent-native Chromium fork with semantic DOM, gRPC, and VLM vision
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

# Neural-Chromium - Agent-Native Browser Runtime

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Chromium fork designed for AI agents with direct browser state access
- **GitHub**: https://github.com/mcpmessenger/neural-chromium
- **License**: BSD-3-Clause (same as Chromium)
- **Languages**: C++ (81%), Python (17%)
- **Status**: Experimental (Phase 3 complete, Windows-only builds currently)
- **Stars**: 4 (early stage project)

**Key Differentiators**:

- **Shared memory + gRPC** for direct browser state access (no CDP/WebSocket overhead)
- **Semantic DOM understanding** via accessibility tree (roles, names, not CSS selectors)
- **VLM-powered vision** via Llama 3.2 Vision (Ollama) for visual reasoning
- **Stealth capabilities** - native event dispatch, no `navigator.webdriver` flag
- **Deep iframe access** - cross-origin frame traversal without context switching

**When to Use**:

- Experimental agent automation requiring semantic element targeting
- CAPTCHA solving research (VLM-based, experimental)
- Dynamic SPA interaction where CSS selectors break frequently
- Privacy-first automation (local VLM, no cloud dependency)

**When NOT to Use** (prefer established tools):

- Production workloads (project is early stage, Windows-only)
- Cross-platform needs (Linux/Mac builds not yet available)
- Quick automation tasks (Playwright is faster and mature)
- Bulk extraction (Crawl4AI is purpose-built)

**Maturity Warning**: Neural-Chromium is an experimental project with 4 stars and 22 commits. It requires building Chromium from source (~4 hours). For production use, prefer Playwright, agent-browser, or dev-browser.

<!-- AI-CONTEXT-END -->

## Architecture

Neural-Chromium modifies Chromium's rendering pipeline to expose internal state directly to AI agents:

```text
AI Agent (Python)
    │
    ├── gRPC Client ──────────────────┐
    │                                  │
    │   Chromium Process               │
    │   ├── Blink Renderer             │
    │   │   └── NeuralPageHandler      │ ← Blink supplement pattern
    │   │       ├── DOM Traversal      │
    │   │       ├── Accessibility Tree │
    │   │       └── Layout Info        │
    │   │                              │
    │   ├── Viz (Compositor)           │
    │   │   └── Shared Memory ─────────┤ ← Zero-copy viewport capture
    │   │                              │
    │   └── In-Process gRPC Server ────┘
    │
    └── VLM (Ollama) ← Llama 3.2 Vision for visual reasoning
```

### Key Components

| Component | Purpose |
|-----------|---------|
| **Visual Cortex** | Zero-copy access to rendering pipeline, 60+ FPS frame processing |
| **High-Precision Action** | Coordinate transformation for mapping agent actions to browser events |
| **Deep State Awareness** | Direct DOM access, 800+ node traversal with parent-child relationships |
| **Local Intelligence** | Llama 3.2 Vision via Ollama for privacy-first visual decision-making |

## Installation

### Prerequisites

- **Windows** (Linux/Mac support planned)
- **Python 3.10+**
- **Ollama** (for VLM features)
- **16GB RAM** (for full Chromium build)
- **depot_tools** (Chromium build toolchain)

### Build from Source

```bash
# Set up depot_tools
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="/path/to/depot_tools:$PATH"

# Clone Neural-Chromium
git clone https://github.com/mcpmessenger/neural-chromium.git
cd neural-chromium

# Sync and build (~4 hours on first run)
cd src
gclient sync
gn gen out/Default
ninja -C out/Default chrome
```

### Install VLM (Optional)

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull vision model
ollama pull llama3.2-vision
```

## Usage

### Start the Runtime

```bash
# Terminal 1: Start Neural-Chromium with remote debugging
out/Default/chrome.exe --remote-debugging-port=9222

# Terminal 2: Start gRPC agent server
python src/glazyr/nexus_agent.py

# Terminal 3: Run automation scripts
python src/demo_saucedemo_login.py
```

### Python API

```python
from nexus_scenarios import AgentClient, AgentAction
import action_pb2

client = AgentClient()
client.navigate("https://www.saucedemo.com")

# Observe page state (semantic DOM snapshot)
state = client.observe()

# Find elements by semantic role (not CSS selectors)
user_field = find(state, role="textbox", name="Username")
pass_field = find(state, role="textbox", name="Password")
login_btn = find(state, role="button", name="Login")

# Type into fields by element ID
client.act(AgentAction(type=action_pb2.TypeAction(
    element_id=user_field.id, text="standard_user"
)))
client.act(AgentAction(type=action_pb2.TypeAction(
    element_id=pass_field.id, text="secret_sauce"
)))

# Click by element ID (no coordinates needed)
client.act(AgentAction(click=action_pb2.ClickAction(
    element_id=login_btn.id
)))
```

### Core Actions

| Action | Method | Description |
|--------|--------|-------------|
| **observe()** | `client.observe()` | Full DOM + accessibility tree snapshot |
| **click(id)** | `AgentAction(click=ClickAction(element_id=id))` | Direct event dispatch by element ID |
| **type(id, text)** | `AgentAction(type=TypeAction(element_id=id, text=text))` | Input injection by element ID |
| **navigate(url)** | `client.navigate(url)` | Navigate to URL |

### VLM CAPTCHA Solving (Experimental)

```bash
# Requires Ollama with llama3.2-vision
python src/vlm_captcha_solve.py
```

The VLM solver captures viewport via shared memory, sends to Llama 3.2 Vision, and receives structured predictions (JSON tile indices with confidence scores).

## Performance Benchmarks

From the project's own benchmarks (10 runs per task, 120s timeout):

| Task | Neural-Chromium | Playwright | Notes |
|------|----------------|------------|-------|
| **Interaction latency** | 1.32s | ~0.5s | NC trades speed for semantic robustness |
| **Auth + data extraction** | 2.3s (100%) | 1.1s (90%) | NC uses semantic selectors |
| **Dynamic SPA (TodoMVC)** | 9.4s (100%) | 3.2s (60%) | NC handles async DOM reliably |
| **Multi-step form** | 4.1s (100%) | 2.8s (95%) | NC uses native event dispatch |
| **CAPTCHA solving** | ~50s (experimental) | N/A (blocked) | VLM-based, contingent on model |

**Key trade-off**: Neural-Chromium is slower in raw latency but claims higher reliability for dynamic SPAs and sites that break CSS selectors frequently.

## Comparison with Existing Tools

| Feature | Neural-Chromium | Playwright | agent-browser | Stagehand |
|---------|----------------|------------|---------------|-----------|
| **Interface** | Python + gRPC | JS/TS API | CLI (Rust) | JS/Python SDK |
| **Element targeting** | Semantic (role/name) | CSS/XPath | Refs from snapshot | Natural language |
| **Browser engine** | Custom Chromium fork | Bundled Chromium | Bundled Chromium | Bundled Chromium |
| **Stealth** | Native (no webdriver) | Detectable | Detectable | Detectable |
| **VLM vision** | Built-in (Ollama) | No | No | No |
| **CAPTCHA handling** | Experimental (VLM) | Blocked | Blocked | Blocked |
| **Iframe access** | Deep traversal | Context switching | Context switching | Context switching |
| **Platform** | Windows only | Cross-platform | Cross-platform | Cross-platform |
| **Maturity** | Experimental | Production | Production | Production |
| **Setup complexity** | Build Chromium (~4h) | `npm install` | `npm install` | `npm install` |

## Roadmap

### Phase 4: Production Hardening (Next)

- Delta updates (only changed DOM nodes, target <500ms latency)
- Push-based events (replace polling with `wait_for_signal`)
- Shadow DOM piercing for modern SPAs
- Multi-tab support for parallel agent execution
- Linux/Mac builds

### Phase 5: Advanced Vision

- OCR integration for text extraction from images
- Visual grounding (click coordinates from natural language)
- Screen diffing for visual change detection

### Phase 6: Ecosystem

- Python SDK (`neural_chromium.Agent()`)
- Docker images for containerized runtime
- Kubernetes operator for cloud deployment

## Repository Structure

```text
neural-chromium/
├── src/
│   ├── glazyr/
│   │   ├── nexus_agent.py          # gRPC server + VisualCortex
│   │   ├── proto/                  # Protocol Buffer definitions
│   │   └── neural_page_handler.*   # Blink C++ integration
│   ├── nexus_scenarios.py          # High-level agent client
│   ├── vlm_solver.py               # Llama Vision integration
│   └── demo_*.py                   # Example flows
├── docs/
│   └── NEURAL_CHROMIUM_ARCHITECTURE.md
├── deployment/                     # Docker/deployment configs
├── tests/                          # Test suite
└── Makefile                        # Build and benchmark commands
```

## Resources

- **GitHub**: https://github.com/mcpmessenger/neural-chromium
- **Live Demo**: https://neuralchrom-dtcvjx99.manus.space
- **Demo Video**: https://youtube.com/shorts/8nOlID7izjQ
- **Twitter**: https://x.com/MCPMessenger
- **License**: BSD-3-Clause
