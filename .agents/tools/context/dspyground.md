---
description: DSPyGround visual prompt optimization playground
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

# DSPyGround Integration Guide

- DSPyGround: Visual prompt optimization playground with GEPA optimizer
- Requires: Node.js 18+, `AI_GATEWAY_API_KEY`; `OPENAI_API_KEY` optional (voice)
- Helper: `./.agents/scripts/dspyground-helper.sh install|init|dev [project]`
- Config: `configs/dspyground-config.json`; project: `dspyground.config.ts`
- Projects: `data/dspyground/[project-name]/` (`.env`, `.dspyground/`)
- Web UI: `http://localhost:3000` (run with `dspyground dev`)
- Metrics: accuracy, tone, efficiency, tool_accuracy, guardrails (customizable)
- Install: `npm install -g dspyground` (optional, on demand)

## Optimization Workflow

| Step | Action |
|------|--------|
| 1. Chat + Sample | Converse with agent; save good responses as positive, bad as negative |
| 2. Organize | Group samples by use case (e.g., "Deployment Tasks", "Security Questions") |
| 3. Optimize | Click "Optimize" — GEPA runs, shows real-time metrics and candidates |
| 4. Export | Copy best prompt from history; update `dspyground.config.ts`; deploy |

Voice feedback: hold spacebar in feedback dialogs to record; auto-transcribed.

## Setup

```bash
./.agents/scripts/dspyground-helper.sh install
cp configs/dspyground-config.json.txt configs/dspyground-config.json
./.agents/scripts/dspyground-helper.sh init my-agent
./.agents/scripts/dspyground-helper.sh dev my-agent
# or from project dir: dspyground dev
```

`.env`:

```bash
AI_GATEWAY_API_KEY=your_key_here
OPENAI_API_KEY=${OPENAI_API_KEY}   # optional, for voice feedback
OPENAI_BASE_URL=https://api.openai.com/v1
```

## Project Config (`dspyground.config.ts`)

```typescript
import { tool } from 'ai'
import { z } from 'zod'

export default {
  systemPrompt: `You are a helpful DevOps assistant...`,
  tools: {
    checkServerStatus: tool({
      description: 'Check the status of a server',
      parameters: z.object({ serverId: z.string() }),
      execute: async ({ serverId }) => `Server ${serverId} is running normally`,
    }),
  },
  schema: z.object({ /* optional structured output shape */ }),
  preferences: {
    selectedModel: 'openai/gpt-4o-mini',
    optimizationModel: 'openai/gpt-4o-mini',
    reflectionModel: 'openai/gpt-4o',
    batchSize: 3, numRollouts: 10,
    selectedMetrics: ['accuracy', 'tone'],
    useStructuredOutput: false,
  },
  metricsPrompt: {
    evaluation_instructions: 'You are an expert DevOps evaluator...',
    dimensions: {
      accuracy:   { name: 'Technical Accuracy',  description: '...', weight: 1.0 },
      tone:       { name: 'Professional Tone',    description: '...', weight: 0.8 },
      // Add custom: { name: '...', description: '...', weight: N }
    },
  },
}
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Server won't start | `node --version` (need 18+); `lsof -i :3000` (check port) |
| API key errors | Check `.env`; test: `curl -H "Authorization: Bearer $AI_GATEWAY_API_KEY" https://api.aigateway.com/v1/models` |
| Optimization failures | Reduce `batchSize: 1, numRollouts: 5` in preferences |

## Resources

- [DSPyGround GitHub](https://github.com/Scale3-Labs/dspyground)
- [AI Gateway Docs](https://docs.aigateway.com/)
- [AI SDK Docs](https://sdk.vercel.ai/)
- [GEPA Algorithm Paper](https://arxiv.org/abs/2310.03714)
