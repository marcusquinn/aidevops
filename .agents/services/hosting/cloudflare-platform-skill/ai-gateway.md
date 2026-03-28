# Cloudflare AI Gateway

Universal gateway for AI model providers with analytics, caching, rate limiting, and routing.

## When to Use

- Setting up AI Gateway for any AI provider (OpenAI, Anthropic, Workers AI, etc.)
- Implementing caching, rate limiting, or request retry/fallback
- Configuring dynamic routing with A/B testing or model fallbacks
- Managing provider API keys securely with BYOK
- Setting up observability with logging and custom metadata
- Integrating AI Gateway with Cloudflare Workers or external applications

## Core Concepts

```
Your App → AI Gateway → AI Provider (OpenAI, Anthropic, etc.)
         ↓
    Analytics, Caching, Rate Limiting, Logging
```

**Key URL patterns:**
- Unified API (OpenAI-compatible): `https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/compat/chat/completions`
- Provider-specific: `https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/{provider}/{endpoint}`
- Dynamic routes: `dynamic/{route-name}`

**Gateway types:**
- **Unauthenticated**: Open access (not recommended for production)
- **Authenticated**: Requires `cf-aig-authorization` header with Cloudflare API token (recommended)

**Provider authentication:**
1. **Unified Billing**: Use AI Gateway billing to pay for inference
2. **BYOK (Store Keys)**: Store provider API keys in Cloudflare dashboard
3. **Request Headers**: Include provider API key in each request

## Common Patterns

### Pattern 1: OpenAI SDK with Unified API Endpoint

Most common pattern — drop-in replacement for OpenAI API with multi-provider support.

```typescript
import OpenAI from 'openai';

const client = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
  baseURL: `https://gateway.ai.cloudflare.com/v1/${accountId}/${gatewayId}/compat`,
  defaultHeaders: {
    'cf-aig-authorization': `Bearer ${cfToken}` // Only needed for authenticated gateways
  }
});

// Switch providers by changing model format: {provider}/{model}
const response = await client.chat.completions.create({
  model: 'openai/gpt-4o-mini', // or 'anthropic/claude-sonnet-4-6'
  messages: [{ role: 'user', content: 'Hello!' }]
});
```

### Pattern 2: Provider-Specific Endpoints

Use when you need the original provider's API schema.

```typescript
const client = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
  baseURL: `https://gateway.ai.cloudflare.com/v1/${accountId}/${gatewayId}/openai`
});
```

### Pattern 3: Workers AI Binding with Gateway

```typescript
export default {
  async fetch(request, env, ctx) {
    const response = await env.AI.run(
      '@cf/meta/llama-3-8b-instruct',
      { messages: [{ role: 'user', content: 'Hello!' }] },
      { gateway: { id: 'my-gateway', metadata: { userId: '123', team: 'engineering' } } }
    );
    return new Response(JSON.stringify(response));
  }
};
```

### Pattern 4: Custom Metadata for Tracking

Tag requests with user IDs, teams, or other identifiers (max 5 metadata entries).

```typescript
const response = await openai.chat.completions.create(
  { model: 'gpt-4o-mini', messages: [{ role: 'user', content: 'Hello!' }] },
  {
    headers: {
      'cf-aig-metadata': JSON.stringify({
        userId: 'user123', team: 'engineering', environment: 'production'
      })
    }
  }
);
```

### Pattern 5: Per-Request Caching Control

```bash
# Skip cache
curl ... --header 'cf-aig-skip-cache: true' ...

# Custom cache TTL (1 hour)
curl ... --header 'cf-aig-cache-ttl: 3600' ...

# Custom cache key
curl ... --header 'cf-aig-cache-key: greeting-response' ...
```

Cache headers: `cf-aig-skip-cache: true` | `cf-aig-cache-ttl: <seconds>` (min 60s, max 1 month) | `cf-aig-cache-key: <key>` | Response: `cf-aig-cache-status: HIT|MISS`

### Pattern 6: BYOK (Bring Your Own Keys)

Store provider keys in dashboard, remove from code.

1. Enable authentication on gateway
2. Dashboard → AI Gateway → Select gateway → Provider Keys → Add API Key
3. Remove provider API keys from code — only `cf-aig-authorization` needed

```typescript
const client = new OpenAI({
  // No apiKey needed - stored in dashboard
  baseURL: `https://gateway.ai.cloudflare.com/v1/${accountId}/${gatewayId}/openai`,
  defaultHeaders: { 'cf-aig-authorization': `Bearer ${cfToken}` }
});
```

### Pattern 7: Dynamic Routing with Fallbacks

```typescript
const response = await client.chat.completions.create({
  model: 'dynamic/support', // Route name from dashboard
  messages: [{ role: 'user', content: 'Hello!' }]
});
```

**Route configuration**: Dashboard → Gateway → Dynamic Routes → Add Route. Node types: Conditional (branch on metadata), Percentage (A/B split), Rate Limit, Budget Limit, Model.

**Use cases**: A/B testing, rate/budget limits per user/team, model fallbacks on errors, conditional routing (paid vs free users).

### Pattern 8: Error Handling

```typescript
try {
  const response = await client.chat.completions.create({ ... });
} catch (error) {
  if (error.status === 429) { /* Rate limit exceeded — implement backoff or use dynamic routing */ }
  if (error.status === 401) { /* Gateway auth failed — check cf-aig-authorization token */ }
  if (error.status === 403) { /* Provider auth failed — check API key or BYOK setup */ }
  throw error;
}
```

## Configuration Reference

### Create Gateway

```bash
# Via Dashboard: AI > AI Gateway > Create Gateway
# Or via API:
curl https://api.cloudflare.com/client/v4/accounts/{account_id}/ai-gateway/gateways \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "my-gateway",
    "cache_ttl": 3600,
    "cache_invalidate_on_update": true,
    "rate_limiting_interval": 60,
    "rate_limiting_limit": 100,
    "rate_limiting_technique": "sliding",
    "collect_logs": true
  }'
```

### Feature Configuration

**Caching**: Dashboard → Settings → Cache Responses → Enable. Only for identical requests (text & image responses). Best for support bots with limited prompt options.

**Rate Limiting**: Dashboard → Settings → Rate-limiting → Enable. Parameters: limit (requests), interval (seconds), technique (`fixed` or `sliding`). Returns `429` when exceeded.

**Logging**: Dashboard → Settings → Logs. Default: enabled (up to 10M logs per gateway). Per-request: `cf-aig-collect-log: false` to skip. Filter by status, cache, provider, model, cost, tokens, duration, metadata.

### Wrangler Integration

```toml
# wrangler.toml
name = "my-worker"
main = "src/index.ts"
compatibility_date = "2024-01-01"

[ai]
binding = "AI"

[[ai.gateway]]
id = "my-gateway"

[vars]
CF_ACCOUNT_ID = "your-account-id"
GATEWAY_ID = "my-gateway"
# Secrets via: wrangler secret put CF_API_TOKEN
```

### API Token Permissions

- AI Gateway - Read (for gateway access)
- AI Gateway - Edit (for gateway management)

## Supported Providers

| Provider | Unified API | Provider Endpoint | Notes |
|----------|-------------|-------------------|-------|
| OpenAI | ✅ `openai/gpt-4o` | `/openai/*` | Full support |
| Anthropic | ✅ `anthropic/claude-sonnet-4-6` | `/anthropic/*` | Full support |
| Google AI Studio | ✅ `google-ai-studio/gemini-2.0-flash` | `/google-ai-studio/*` | Full support |
| Workers AI | ✅ `workersai/@cf/meta/llama-3` | `/workers-ai/*` | Native integration |
| Azure OpenAI | ✅ `azure-openai/*` | `/azure-openai/*` | Deployment names |
| AWS Bedrock | ❌ | `/bedrock/*` | Provider endpoint only |
| Groq | ✅ `groq/*` | `/groq/*` | Fast inference |
| Mistral | ✅ `mistral/*` | `/mistral/*` | Full support |
| Cohere | ✅ `cohere/*` | `/cohere/*` | Full support |
| Perplexity | ✅ `perplexity/*` | `/perplexity/*` | Full support |
| xAI (Grok) | ✅ `grok/*` | `/grok/*` | Full support |
| DeepSeek | ✅ `deepseek/*` | `/deepseek/*` | Full support |
| Cerebras | ✅ `cerebras/*` | `/cerebras/*` | Fast inference |
| Replicate | ❌ | `/replicate/*` | Provider endpoint only |
| HuggingFace | ❌ | `/huggingface/*` | Provider endpoint only |

See [full provider list](https://developers.cloudflare.com/ai-gateway/usage/providers/)

## Observability

**Analytics Dashboard** (Dashboard → AI Gateway → Select gateway): request count, token usage, cost tracking, cache hit rate, error rates, latency percentiles.

**Log entry fields**: user prompt & model response, provider & model, timestamp, status, token usage, cost, duration (ms), cache status, custom metadata, request/event ID.

**Custom cost tracking** (for models not in Cloudflare's pricing database):

```bash
curl https://api.cloudflare.com/client/v4/accounts/{account_id}/ai-gateway/gateways/{gateway_id}/custom-costs \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -d '{"model": "custom-model-v1", "input_cost": 0.01, "output_cost": 0.03}'
```

## Advanced Use Cases

### Multi-Model Chat with Fallbacks

Configure in dashboard: Route `dynamic/smart-chat` → Try GPT-4 first → Fallback to Claude if error → Fallback to Llama if both fail.

```typescript
const response = await client.chat.completions.create({
  model: 'dynamic/smart-chat',
  messages: [{ role: 'user', content: 'Complex reasoning task' }]
});
```

### A/B Testing Models

Dashboard: Create route with Percentage node (50% gpt-4o-mini, 50% claude-sonnet-4-6). Analyze logs to compare quality/cost/latency.

```typescript
const response = await client.chat.completions.create({
  model: 'dynamic/ab-test',
  messages: [{ role: 'user', content: prompt }],
  headers: { 'cf-aig-metadata': JSON.stringify({ experiment: 'model-comparison-v1' }) }
});
```

### Semantic Caching (Future)

Currently, caching requires identical requests. Semantic caching is planned. Workaround: use `cf-aig-cache-key` with a normalized/hashed prompt.

## Debugging & Troubleshooting

### Common Issues

| Error | Cause | Fix |
|-------|-------|-----|
| **401 Unauthorized** | Missing/invalid `cf-aig-authorization` | Check token permissions (AI Gateway - Read) |
| **403 Forbidden** | Provider API key invalid/missing | Check BYOK config or provider quota |
| **429 Rate Limited** | Gateway rate limit exceeded | Implement backoff or use dynamic routing |
| **Cache not working** | Requests not identical, or caching disabled | Check `cf-aig-cache-status` header, verify caching enabled |
| **Logs not appearing** | Log limit reached or logging disabled | Check 10M limit, verify logs enabled, wait 30-60s |

### Check Gateway Status

```bash
# List all gateways
curl https://api.cloudflare.com/client/v4/accounts/{account_id}/ai-gateway/gateways \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

Dashboard → Gateway → Logs. Filter examples: `status: error`, `provider: openai`, `metadata.userId: user123`, `cost > 0.01`.

## API Reference

```bash
# Gateway management
POST   /accounts/{account_id}/ai-gateway/gateways
PUT    /accounts/{account_id}/ai-gateway/gateways/{gateway_id}
DELETE /accounts/{account_id}/ai-gateway/gateways/{gateway_id}
GET    /accounts/{account_id}/ai-gateway/gateways

# Log management
GET    /accounts/{account_id}/ai-gateway/gateways/{gateway_id}/logs
DELETE /accounts/{account_id}/ai-gateway/gateways/{gateway_id}/logs
# Filter: ?status=error&provider=openai&cache=not_cached
```

### Headers Reference

| Header | Purpose |
|--------|---------|
| `cf-aig-authorization: Bearer {token}` | Required for authenticated gateways |
| `cf-aig-cache-ttl: {seconds}` | Cache duration (60s - 1 month) |
| `cf-aig-skip-cache: true` | Bypass cache |
| `cf-aig-cache-key: {key}` | Custom cache key |
| `cf-aig-collect-log: false` | Skip logging for this request |
| `cf-aig-metadata: {json}` | Custom tracking data (max 5 entries) |

## Best Practices

1. **Always use authenticated gateways in production** — prevents unauthorized access, required for BYOK
2. **Use BYOK for provider keys** — removes keys from codebase, easier rotation, centralized management
3. **Add custom metadata to all requests** — track users/teams/environments, filter logs effectively
4. **Configure appropriate rate limits** — prevent runaway costs, use dynamic routing for per-user limits
5. **Enable caching for deterministic prompts** — support bots, static content generation, reduces costs & latency
6. **Use dynamic routing for resilience** — model fallbacks, A/B testing without code changes, gradual rollouts
7. **Monitor logs regularly** — set up automatic log deletion, export for long-term analysis, track cost trends
8. **Test with provider-specific endpoints first** — validates provider integration, easier debugging

## Examples Repository

- [NextChat](https://github.com/ChatGPTNextWeb/NextChat/blob/main/app/utils/cloudflare.ts) - URL parsing utilities
- [LibreChat](https://github.com/danny-avila/LibreChat) - Multi-provider chat with AI Gateway
- [Continue.dev](https://github.com/continuedev/continue/blob/main/core/llm/llms/Cloudflare.ts) - IDE integration
- [Big-AGI](https://github.com/enricoros/big-AGI) - Complex gateway path handling

## Resources

- [Official Docs](https://developers.cloudflare.com/ai-gateway/)
- [API Reference](https://developers.cloudflare.com/api/resources/ai_gateway/)
- [Provider Guides](https://developers.cloudflare.com/ai-gateway/usage/providers/)
- [Workers AI Integration](https://developers.cloudflare.com/workers-ai/)
- [Discord Community](https://discord.cloudflare.com)

## Quick Reference

```bash
# Create gateway
Dashboard → AI → AI Gateway → Create Gateway

# Basic request
const client = new OpenAI({
  baseURL: `https://gateway.ai.cloudflare.com/v1/${accountId}/${gatewayId}/compat`
});

# Required env vars
CF_ACCOUNT_ID=xxx  GATEWAY_ID=xxx  CF_API_TOKEN=xxx  PROVIDER_API_KEY=xxx

# Account ID: Dashboard → Overview → Account ID
# Gateway ID: Dashboard → AI Gateway → Gateway name/ID
```
