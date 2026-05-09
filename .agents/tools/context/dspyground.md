---
description: DSPyGround visual prompt optimization playground
mode: subagent
tools:
  read: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# DSPyGround Integration Guide

- Visual prompt optimization playground with GEPA optimizer
- Requires: Node.js 18+, `AI_GATEWAY_API_KEY`; `OPENAI_API_KEY` optional (voice)
- Helper: `dspyground-helper.sh install|init|dev [project]`
- Config: `configs/dspyground-config.json`; project: `dspyground.config.ts`
- Projects: `data/dspyground/[project-name]/` (`.env`, `.dspyground/`)
- Web UI: `http://localhost:3000` | Metrics: accuracy, tone, efficiency, tool_accuracy, guardrails

## Setup

```bash
dspyground-helper.sh install
cp configs/dspyground-config.json.txt configs/dspyground-config.json
dspyground-helper.sh init my-agent && dspyground-helper.sh dev my-agent
```

`.env`: `AI_GATEWAY_API_KEY=your_key` | `OPENAI_API_KEY=...` (optional, voice) | `OPENAI_BASE_URL=https://api.openai.com/v1`

## Optimization Workflow

| Step | Action |
|------|--------|
| 1. Chat + Sample | Converse with agent; save good/bad responses as positive/negative. Voice: hold spacebar to record. |
| 2. Organize | Group samples by use case (e.g., "Deployment Tasks") |
| 3. Optimize | Click "Optimize" — GEPA runs, shows real-time metrics and candidates |
| 4. Export | Copy best prompt from history; update `dspyground.config.ts`; deploy |

## Project Config (`dspyground.config.ts`)

```typescript
import { tool } from 'ai'; import { z } from 'zod'
export default {
  systemPrompt: `You are a helpful DevOps assistant...`,
  tools: {
    checkServerStatus: tool({
      description: 'Check the status of a server',
      parameters: z.object({ serverId: z.string() }),
      execute: async ({ serverId }) => `Server ${serverId} is running normally`,
    }),
  },
  preferences: {
    selectedModel: 'openai/gpt-4o-mini', optimizationModel: 'openai/gpt-4o-mini',
    reflectionModel: 'openai/gpt-4o', batchSize: 3, numRollouts: 10,
    selectedMetrics: ['accuracy', 'tone'], useStructuredOutput: false,
  },
  metricsPrompt: {
    evaluation_instructions: 'You are an expert DevOps evaluator...',
    dimensions: {
      accuracy: { name: 'Technical Accuracy', weight: 1.0 },
      tone:     { name: 'Professional Tone',  weight: 0.8 },
      // custom: { name: '...', weight: N }
    },
  },
}
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Server won't start | `node --version` (need 18+); `lsof -i :3000` (port conflict) |
| API key errors | Check `.env`; test: `curl -H "Authorization: Bearer $AI_GATEWAY_API_KEY" https://api.aigateway.com/v1/models` |
| Optimization failures | Reduce `batchSize: 1, numRollouts: 5` in preferences |

**Resources:** [GitHub](https://github.com/Scale3-Labs/dspyground) · [AI Gateway](https://docs.aigateway.com/) · [AI SDK](https://sdk.vercel.ai/) · [GEPA Paper](https://arxiv.org/abs/2310.03714)
