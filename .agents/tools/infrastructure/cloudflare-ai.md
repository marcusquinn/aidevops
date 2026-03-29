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

- **CLI**: `wrangler` — `npm install -g wrangler` | `wrangler ai models` (list models)
- **API base**: `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/{model}`
- **Auth**: Cloudflare API token or `wrangler login`
- **Creds**: `CLOUDFLARE_API_TOKEN` env var | `CLOUDFLARE_ACCOUNT_ID`
- **Docs**: [developers.cloudflare.com/workers-ai](https://developers.cloudflare.com/workers-ai/) | [Pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/) | [Models](https://developers.cloudflare.com/workers-ai/models/)
- **Dashboard**: [dash.cloudflare.com](https://dash.cloudflare.com/?to=/:account/ai/workers-ai)
- **Free tier**: 10,000 Neurons/day (both Free and Paid Workers plans)

<!-- AI-CONTEXT-END -->

Serverless AI inference on Cloudflare's global GPU network. Models run at the edge, close to users. Part of the Cloudflare developer platform (Workers, Pages, KV, D1, R2, Vectorize, AI Gateway).

## Pricing (March 2026)

Billed in Neurons ($0.011 per 1,000 Neurons). Free allocation: 10,000 Neurons/day on both Free and Paid Workers plans.

### LLM Pricing (selected models)

| Model | $/M input | $/M output |
|-------|-----------|------------|
| Llama 3.2 1B | $0.027 | $0.201 |
| Llama 3.2 3B | $0.051 | $0.335 |
| Llama 3.1 8B FP8 Fast | $0.045 | $0.384 |
| Llama 3.3 70B FP8 Fast | $0.293 | $2.253 |
| Llama 4 Scout 17B | $0.270 | $0.850 |
| DeepSeek R1 Distill Qwen 32B | $0.497 | $4.881 |
| Qwen3 30B A3B FP8 | $0.051 | $0.335 |
| GPT-OSS 120B | $0.350 | $0.750 |
| GPT-OSS 20B | $0.200 | $0.300 |
| Kimi K2.5 | $0.600 | $3.000 |
| Nemotron 3 120B A12B | $0.500 | $1.500 |
| Mistral 7B | $0.110 | $0.190 |
| Mistral Small 3.1 24B | $0.351 | $0.555 |

### Other Modalities

| Type | Model | Price |
|------|-------|-------|
| Embeddings | BGE Small/Base/Large | $0.008-$0.204/M tokens |
| Image | FLUX.1 Schnell | $0.00035/step |
| Image | FLUX.2 Klein 4B | $0.000059/input tile |
| Audio STT | Whisper Large v3 Turbo | $0.0005/min |
| Audio TTS | MeloTTS | $0.0002/min |
| Audio TTS | Deepgram Aura 2 | $0.030/1K chars |
| Reranking | BGE Reranker Base | $0.003/M tokens |

### Price Comparison vs Fireworks/Together

Cloudflare is generally **more expensive for large models** but **competitive or cheaper for small models**:

| Model | Cloudflare | Fireworks | Together |
|-------|------------|-----------|---------|
| GPT-OSS 120B (in/out) | $0.35/$0.75 | $0.15/$0.60 | $0.15/$0.60 |
| Llama 3.3 70B (in/out) | $0.29/$2.25 | $0.90/$0.90 | $0.88/$0.88 |
| Qwen3 30B A3B (in/out) | $0.05/$0.34 | $0.15/$0.60 | $0.15/$1.50 |
| Mistral 7B (in/out) | $0.11/$0.19 | $0.20/$0.20 | $0.20/$0.20 |

Pattern: CF has cheap input but expensive output for large models. Best value for small models (<16B).

## Usage

### From Workers (recommended)

```javascript
// In a Cloudflare Worker
export default {
  async fetch(request, env) {
    const response = await env.AI.run("@cf/meta/llama-3.3-70b-instruct-fp8-fast", {
      messages: [{ role: "user", content: "Hello" }]
    });
    return Response.json(response);
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

Cloudflare provides an OpenAI-compatible endpoint for supported models. See [OpenAI compat docs](https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/) for supported models and limitations.

## Capabilities

**Available**: ~30 LLM models (Llama, Qwen, Mistral, DeepSeek distills, GPT-OSS, Gemma), image generation (FLUX, Stable Diffusion), STT (Whisper, Deepgram Nova), TTS (MeloTTS, Deepgram Aura), embeddings (BGE, Qwen3), reranking, classification, translation, object detection, AI Gateway (caching, rate limiting, retries, fallback, analytics), Vectorize (RAG), streaming.

**Not available**: fine-tuning (use Fireworks/Together), custom model uploads ([form required](https://forms.gle/axnnpGDb6xrmR31T6)), dedicated GPUs, batch inference, large frontier models (DeepSeek V3 full, GLM-5 — distills only), self-hosted, Anthropic SDK (use CF API or OpenAI-compat).

**Platform integration**: Workers AI compounds with AI Gateway (caching/rate limiting/fallback), Vectorize (RAG), Workers (pre/post-processing), KV/D1/R2 (storage), Pages (frontend).

## When to Use

| Scenario | Recommendation |
|----------|---------------|
| Cloudflare-native app needing AI | Strong fit — native binding (`env.AI`) |
| Edge inference, low latency globally | Strong fit — runs on CF network |
| Small model inference (<16B) | Good value — competitive pricing |
| Free experimentation | Good fit — 10K neurons/day free |
| Large model production inference | Use Fireworks or Together instead |
| Fine-tuning or custom models | Use Fireworks or Together instead |
| Batch processing at scale | Use Fireworks or Together instead |
| Privacy-critical workloads | Use NEAR AI instead |

## Security

- Store credentials: `aidevops secret set CLOUDFLARE_API_TOKEN` and `aidevops secret set CLOUDFLARE_ACCOUNT_ID`
- Never expose tokens in logs or output
- Use Workers bindings (`env.AI`) instead of raw API calls when possible
- AI Gateway provides rate limiting and abuse protection

## See Also

- `tools/infrastructure/fireworks.md` -- managed inference + fine-tuning (more models, cheaper for large)
- `tools/infrastructure/together.md` -- managed inference + GPU clusters
- `tools/infrastructure/nearai.md` -- TEE-backed private inference
- `tools/deployment/hosting-comparison.md` -- full platform comparison
- Cloudflare platform skill: load with `/skill cloudflare-platform-skill`
