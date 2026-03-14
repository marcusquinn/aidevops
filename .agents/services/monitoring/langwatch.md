---
description: LangWatch — LLM observability, evaluation, and agent testing (self-hosted)
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
---

# LangWatch

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: LLM trace observability, offline evaluation, agent simulation testing
- **Repo**: [langwatch/langwatch](https://github.com/langwatch/langwatch) (BSL 1.1 — see License below)
- **Self-host**: Docker Compose — 6 containers (app, NLP, langevals, postgres, redis, opensearch)
- **Local URL**: `https://langwatch.local` (via localdev)
- **Port**: 5560 (default)
- **Docs**: [docs.langwatch.ai](https://docs.langwatch.ai)

**When to use**:

- Tracing LLM calls across agent pipelines (latency, tokens, cost)
- Running offline evaluations and regression tests on prompts/models
- Simulating end-to-end agent scenarios before production
- Detecting hallucinations, quality regressions, and cost spikes
- Prompt versioning with trace linkage

**When NOT to use** (use these instead):

- Application error monitoring → Sentry (`services/monitoring/sentry.md`)
- Dependency security scanning → Socket (`services/monitoring/socket.md`)
- Basic LLM request metrics (no UI needed) → `observability-helper.sh`

<!-- AI-CONTEXT-END -->

## What LangWatch Does

LangWatch is an LLM-specific observability platform. Where Sentry catches application crashes, LangWatch catches LLM-layer problems: hallucinations, quality regressions, cost spikes, latency outliers, and prompt drift.

Core capabilities:

| Feature | What it does |
|---------|-------------|
| **Trace collection** | Captures every LLM call with spans, tokens, latency, cost — OpenTelemetry native |
| **Offline evaluation** | Run eval suites against datasets to measure quality before deploying prompt changes |
| **Agent simulation** | Test full agent stacks (tools, state, user simulator, judge) against realistic scenarios |
| **Prompt management** | Version prompts, link versions to traces, GitHub integration for prompt-as-code |
| **Guardrails** | PII redaction, content filtering, custom evaluators via LangEvals |
| **Annotations** | Domain experts label edge cases, review runs, build evaluation datasets from production traces |

### Comparison with existing aidevops observability

| Concern | Current tool | LangWatch adds |
|---------|-------------|----------------|
| LLM request logging | `observability-helper.sh` (JSONL) | Structured traces with UI, filtering, analytics |
| Error monitoring | Sentry | LLM-specific: hallucination detection, quality scoring |
| Eval/regression | Manual review | Automated offline evals, dataset management |
| Agent testing | None | End-to-end scenario simulation |
| Cost tracking | Basic token counts | Per-model, per-project cost dashboards |

### Decision factors

**Add LangWatch when:**

- You're running multiple agents or LLM-powered services and need visibility into quality/cost trends
- You want regression testing for prompt changes (eval datasets + automated scoring)
- You need to debug agent decision chains across multiple LLM calls
- Domain experts need to review and annotate LLM outputs without touching code

**Skip LangWatch when:**

- You only need basic "how many tokens did I use" metrics — `observability-helper.sh` is sufficient
- You're running a single simple LLM integration with no quality concerns
- Resource-constrained machine — the 6-container stack needs ~1-1.5GB RAM

## License

**BSL 1.1** (Business Source License). This is NOT open source.

- Self-hosting for internal/development use is permitted
- The "Additional Use Grant" is **None** — production/commercial use technically requires a commercial license
- Change date is 2099 (converts to Apache 2.0 then)
- Cloud version available at [app.langwatch.ai](https://app.langwatch.ai) (free tier exists)

**Recommendation**: Fine for local dev/testing. If you plan to use it in production for a commercial product, review the license terms or use the cloud version.

## Self-Hosting Setup

### Prerequisites

- Docker and Docker Compose
- ~1.5GB free RAM (OpenSearch 256MB + Postgres + Redis + app + NLP)
- `localdev-helper.sh` initialised (for `.local` domain + SSL)

### 1. Clone and configure

```bash
git clone https://github.com/langwatch/langwatch.git ~/Git/langwatch
cd ~/Git/langwatch
cp .env.example .env
```

### 2. Generate secrets

Edit `.env` and replace the placeholder secrets:

```bash
# Generate and set secrets (do NOT commit these)
NEXTAUTH_SECRET="$(openssl rand -base64 32)"
CREDENTIALS_SECRET="$(openssl rand -base64 32)"
API_TOKEN_JWT_SECRET="$(openssl rand -base64 32)"
```

### 3. Configure LLM provider keys

LangWatch needs API keys for the LLM providers it evaluates against. Add to `.env`:

```bash
# At minimum, one of these for embeddings + evals
OPENAI_API_KEY=       # From credentials.sh or gopass
ANTHROPIC_API_KEY=    # From credentials.sh or gopass
```

Source from aidevops credential store:

```bash
source ~/.config/aidevops/credentials.sh
# Then set in .env accordingly
```

### 4. Register with localdev

```bash
# Register the .local domain and SSL cert
localdev-helper.sh add langwatch --port 5560

# Result: https://langwatch.local → localhost:5560
```

### 5. Start services

```bash
cd ~/Git/langwatch
docker compose up -d --wait
```

Verify: open `https://langwatch.local` — you should see the LangWatch setup screen. Create your first project and API key.

### 6. Daily updates (optional)

To keep LangWatch updated via the pulse schedule:

```bash
# Pull latest images and restart
cd ~/Git/langwatch && docker compose pull && docker compose up -d --wait
```

This can be added to a launchd plist (`sh.aidevops.langwatch-update`) or run manually.

## Integration with aidevops

### OpenTelemetry traces

LangWatch is OTLP-native. To send traces from your application:

```python
# Python SDK
pip install langwatch

import langwatch
langwatch.api_key = "your-project-api-key"
langwatch.endpoint = "https://langwatch.local"

@langwatch.trace()
def my_agent_function():
    # Your LLM calls here — automatically traced
    pass
```

```typescript
// TypeScript SDK
import { LangWatch } from "langwatch";

const lw = new LangWatch({
  apiKey: "your-project-api-key",
  endpoint: "https://langwatch.local",
});
```

### Framework integrations

LangWatch has native integrations for: LangChain, LangGraph, Vercel AI SDK, Mastra, CrewAI, Google ADK. See [integration docs](https://docs.langwatch.ai/integration/overview).

For any OpenTelemetry-compatible framework, point the OTLP exporter at `https://langwatch.local`.

### LangWatch MCP server

LangWatch provides an MCP server for use in Claude Desktop and other MCP clients:

```bash
# See https://docs.langwatch.ai/integration/mcp for setup
```

## Architecture

```text
Docker Compose stack:

  langwatch/langwatch:latest     → Main app (Next.js) on :5560
  langwatch/langwatch_nlp:latest → NLP service (optimization studio, clustering) on :5561
  langwatch/langevals:latest     → Evaluators and guardrails on :5562
  postgres:16                    → Primary data store on :5432
  redis:alpine                   → Queue backend on :6379
  langwatch/opensearch-lite      → Trace storage + search on :9200
```

**Port conflicts**: The default ports (5432, 6379) may conflict with existing local services. If using the shared localdev Postgres, update `DATABASE_URL` in `.env` to point at the shared instance and remove the `postgres` service from `docker-compose.yml`.

## Troubleshooting

### Container won't start — port conflict

```bash
# Check what's using the port
lsof -i :5432  # Postgres
lsof -i :6379  # Redis
lsof -i :9200  # OpenSearch
```

Either stop the conflicting service or remap ports in `docker-compose.yml`.

### OpenSearch out of memory

The default config limits OpenSearch to 256MB. If it OOMs on large trace volumes:

```yaml
# In docker-compose.yml, increase the limit
environment:
  - "OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m"
deploy:
  resources:
    limits:
      memory: 512m
```

### SSL certificate issues with langwatch.local

Ensure localdev is initialised and the cert exists:

```bash
localdev-helper.sh status langwatch
# If missing: localdev-helper.sh add langwatch --port 5560
```

## Related

- [LangWatch Documentation](https://docs.langwatch.ai)
- [LangWatch GitHub](https://github.com/langwatch/langwatch)
- [Self-hosting guide](https://docs.langwatch.ai/self-hosting/overview)
- Sentry (error monitoring): `services/monitoring/sentry.md`
- Observability helper (basic metrics): `scripts/observability-helper.sh`
