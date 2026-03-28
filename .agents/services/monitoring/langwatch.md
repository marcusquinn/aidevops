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
- **Local URL**: `https://langwatch.local` (via localdev) · **Port**: 5560
- **Docs**: [docs.langwatch.ai](https://docs.langwatch.ai)

| Feature | Description |
|---------|-------------|
| **Trace collection** | Every LLM call with spans, tokens, latency, cost — OpenTelemetry native |
| **Offline evaluation** | Eval suites against datasets; measure quality before deploying prompt changes |
| **Agent simulation** | Test full agent stacks (tools, state, user simulator, judge) against realistic scenarios |
| **Prompt management** | Version prompts, link to traces, GitHub integration for prompt-as-code |
| **Guardrails** | PII redaction, content filtering, custom evaluators via LangEvals |
| **Annotations** | Domain experts label edge cases, build eval datasets from production traces |

**When to use**: Tracing LLM calls (latency/tokens/cost), offline eval + regression testing, agent scenario simulation, hallucination/quality/cost detection, prompt versioning, domain expert annotation, debugging multi-call agent chains.

**When NOT to use** (use these instead):
- Application error monitoring → Sentry (`services/monitoring/sentry.md`)
- Dependency security scanning → Socket (`services/monitoring/socket.md`)
- Basic LLM request metrics (no UI needed) → `observability-helper.sh`
- Single simple LLM integration with no quality concerns → skip LangWatch
- Resource-constrained (<1.5GB free RAM) → `observability-helper.sh`

### vs existing aidevops observability

| Concern | Current | LangWatch adds |
|---------|---------|----------------|
| LLM logging | `observability-helper.sh` (JSONL) | Structured traces with UI, filtering, analytics |
| Error monitoring | Sentry | Hallucination detection, quality scoring |
| Eval/regression | Manual review | Automated offline evals, dataset management |
| Agent testing | None | End-to-end scenario simulation |
| Cost tracking | Basic token counts | Per-model, per-project dashboards |

<!-- AI-CONTEXT-END -->

## License

**BSL 1.1** (Business Source License) — NOT open source. Self-hosting for internal/dev use: permitted. Additional Use Grant: **None** (production/commercial use requires commercial license). Change date: 2099 (→ Apache 2.0). Cloud: [app.langwatch.ai](https://app.langwatch.ai) (free tier). Fine for local dev/testing; review license terms for production commercial use.

## Self-Hosting Setup

**Prerequisites**: Docker + Docker Compose, ~1.5GB free RAM, `localdev-helper.sh` initialised.

### 1. Clone and configure

```bash
git clone https://github.com/langwatch/langwatch.git ~/Git/langwatch
cd ~/Git/langwatch
cp .env.example .env
```

### 2. Set secrets and API keys in `.env`

```bash
# Generate secrets (do NOT commit)
NEXTAUTH_SECRET="$(openssl rand -base64 32)"
CREDENTIALS_SECRET="$(openssl rand -base64 32)"
API_TOKEN_JWT_SECRET="$(openssl rand -base64 32)"

# LLM provider keys for evals (at minimum one)
OPENAI_API_KEY=       # From credentials.sh or gopass
ANTHROPIC_API_KEY=    # From credentials.sh or gopass
```

Source from aidevops credential store: `source ~/.config/aidevops/credentials.sh`

### 3. Register with localdev and start

```bash
localdev-helper.sh add langwatch --port 5560
# Result: https://langwatch.local → localhost:5560

cd ~/Git/langwatch
docker compose up -d --wait
```

Verify: open `https://langwatch.local` — create your first project and API key.

### 4. Updates (optional)

```bash
cd ~/Git/langwatch && docker compose pull && docker compose up -d --wait
```

Can be added to a launchd plist (`sh.aidevops.langwatch-update`) or run manually.

## Integration

### OpenTelemetry traces (OTLP-native)

```python
pip install langwatch

import langwatch
langwatch.api_key = "your-project-api-key"
langwatch.endpoint = "https://langwatch.local"

@langwatch.trace()
def my_agent_function():
    # LLM calls automatically traced
    pass
```

```typescript
import { LangWatch } from "langwatch";

const lw = new LangWatch({
  apiKey: "your-project-api-key",
  endpoint: "https://langwatch.local",
});
```

### Framework integrations

Native: LangChain, LangGraph, Vercel AI SDK, Mastra, CrewAI, Google ADK. See [integration docs](https://docs.langwatch.ai/integration/overview). For any OTLP-compatible framework, point the exporter at `https://langwatch.local`.

### MCP server

See [MCP setup docs](https://docs.langwatch.ai/integration/mcp) for Claude Desktop and other MCP clients.

## Architecture

```text
langwatch/langwatch:latest     → Main app (Next.js) on :5560
langwatch/langwatch_nlp:latest → NLP service (optimization studio, clustering) on :5561
langwatch/langevals:latest     → Evaluators and guardrails on :5562
postgres:16                    → Primary data store on :5432
redis:alpine                   → Queue backend on :6379
langwatch/opensearch-lite      → Trace storage + search on :9200
```

**Port conflicts**: Defaults (5432, 6379) may conflict with local services. If using shared localdev Postgres, update `DATABASE_URL` in `.env` and remove the `postgres` service from `docker-compose.yml`.

## Troubleshooting

### Port conflict

```bash
lsof -i :5432  # Postgres
lsof -i :6379  # Redis
lsof -i :9200  # OpenSearch
```

Stop the conflicting service or remap ports in `docker-compose.yml`.

### OpenSearch OOM

Default limits OpenSearch to 256MB. For large trace volumes, increase in `docker-compose.yml`:

```yaml
environment:
  - "OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m"
deploy:
  resources:
    limits:
      memory: 512m
```

### SSL certificate issues

```bash
localdev-helper.sh status langwatch
# If missing: localdev-helper.sh add langwatch --port 5560
```

## Related

- [LangWatch Documentation](https://docs.langwatch.ai) · [GitHub](https://github.com/langwatch/langwatch) · [Self-hosting guide](https://docs.langwatch.ai/self-hosting/overview)
- Sentry (error monitoring): `services/monitoring/sentry.md`
- Observability helper (basic metrics): `scripts/observability-helper.sh`
