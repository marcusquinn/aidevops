---
description: "Cloudflare Workers AI — edge serverless inference on Cloudflare's global GPU network, pay-per-neuron pricing, Wrangler CLI"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: false
---

# Cloudflare Workers AI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `wrangler` — `npm install -g wrangler` | `wrangler ai models` (list)
- **API**: `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/{model}`
- **Auth**: Cloudflare API token or `wrangler login`
- **Creds**: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **Docs**: [workers-ai](https://developers.cloudflare.com/workers-ai/) | [Pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/) | [Models](https://developers.cloudflare.com/workers-ai/models/)
- **Dashboard**: [dash.cloudflare.com](https://dash.cloudflare.com/?to=/:account/ai/workers-ai)
- **Free tier**: 10,000 Neurons/day (Free and Paid plans)

<!-- AI-CONTEXT-END -->

## Usage

### Workers Binding (recommended)

```javascript
export default {
  async fetch(request, env) {
    const res = await env.AI.run("@cf/meta/llama-3.3-70b-instruct-fp8-fast", {
      messages: [{ role: "user", content: "Hello" }]
    });
    return Response.json(res);
  }
};
```

### REST API

```bash
curl https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/run/@cf/meta/llama-3.3-70b-instruct-fp8-fast \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -d '{"messages": [{"role": "user", "content": "Hello"}]}'
```

### OpenAI-Compatible Endpoint

[Docs](https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/) — supported models and limitations.

## Capabilities

**Available**: ~30 LLMs (Llama, Qwen, Mistral, DeepSeek, GPT-OSS, Gemma), image gen (FLUX, SD), STT (Whisper, Deepgram Nova), TTS (MeloTTS, Deepgram Aura), embeddings (BGE, Qwen3), reranking, classification, translation, object detection, AI Gateway (caching/rate limiting/retries/fallback/analytics), Vectorize (RAG), streaming.
**Not available**: fine-tuning, custom model uploads ([form](https://forms.gle/axnnpGDb6xrmR31T6)), dedicated GPUs, batch inference, large frontier models (distills only), Anthropic SDK (use CF API or OpenAI-compat).
**Platform integration**: AI Gateway + Vectorize (RAG) + Workers (processing) + KV/D1/R2 (storage) + Pages (frontend).

## Pricing

Billed in Neurons ($0.011/1K Neurons). Free: 10K Neurons/day.

### LLM Pricing ($/M input/output)

| Model | In | Out | Model | In | Out |
|-------|----|-----|-------|----|-----|
| Llama 3.2 1B | $0.03 | $0.20 | Llama 3.2 3B | $0.05 | $0.34 |
| Llama 3.1 8B | $0.05 | $0.38 | Llama 3.3 70B | $0.29 | $2.25 |
| Llama 4 17B | $0.27 | $0.85 | DeepSeek 32B | $0.50 | $4.88 |
| Qwen3 30B | $0.05 | $0.34 | GPT-OSS 120B | $0.35 | $0.75 |
| GPT-OSS 20B | $0.20 | $0.30 | Kimi K2.5 | $0.60 | $3.00 |
| Nemotron 120B | $0.50 | $1.50 | Mistral 7B | $0.11 | $0.19 |
| Mistral 24B | $0.35 | $0.56 | | | |

### Other Modalities

| Type | Model | Price |
|------|-------|-------|
| Embeddings | BGE Small/Base/Large | $0.01-$0.20/M tokens |
| Image | FLUX.1 Schnell | $0.00035/step |
| Image | FLUX.2 Klein 4B | $0.00006/tile |
| Audio STT | Whisper v3 Turbo | $0.0005/min |
| Audio TTS | MeloTTS | $0.0002/min |
| Audio TTS | Deepgram Aura 2 | $0.03/1K chars |
| Reranking | BGE Reranker Base | $0.003/M tokens |

### Price Comparison (in/out)

| Model | Cloudflare | Fireworks | Together |
|-------|------------|-----------|---------|
| GPT-OSS 120B | $0.35/$0.75 | $0.15/$0.60 | $0.15/$0.60 |
| Llama 3.3 70B | $0.29/$2.25 | $0.90/$0.90 | $0.88/$0.88 |
| Qwen3 30B | $0.05/$0.34 | $0.15/$0.60 | $0.15/$1.50 |
| Mistral 7B | $0.11/$0.19 | $0.20/$0.20 | $0.20/$0.20 |

Cheap input, expensive output for large models. Best value: small models (<16B).

## When to Use

| Scenario | Recommendation |
|----------|---------------|
| CF-native app needing AI | Strong fit — native `env.AI` binding |
| Edge inference, global low latency | Strong fit — CF network |
| Small models (<16B) | Good value — competitive pricing |
| Free experimentation | 10K neurons/day free |
| Large models / fine-tuning / batch | Fireworks or Together instead |
| Privacy-critical | NEAR AI instead |

## Security

- Credentials: `aidevops secret set CLOUDFLARE_API_TOKEN` / `aidevops secret set CLOUDFLARE_ACCOUNT_ID`
- Prefer Workers bindings (`env.AI`) over raw API calls
- AI Gateway for rate limiting and abuse protection

## See Also

- `tools/infrastructure/fireworks.md` -- inference + fine-tuning (cheaper for large models)
- `tools/infrastructure/together.md` -- inference + GPU clusters
- `tools/infrastructure/nearai.md` -- TEE-backed private inference
- `tools/deployment/hosting-comparison.md` -- platform comparison
- Cloudflare platform skill: `/skill cloudflare-platform-skill`

