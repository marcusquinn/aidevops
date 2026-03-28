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

<!-- AI-CONTEXT-START -->

## Quick Reference

- DSPyGround: Visual prompt optimization playground with GEPA optimizer
- Requires: Node.js 18+, AI Gateway API key
- Helper: `./.agents/scripts/dspyground-helper.sh install|init|dev [project]`
- Config: `configs/dspyground-config.json`, project: `dspyground.config.ts`
- Projects: `data/dspyground/[project-name]/`
- Web UI: `http://localhost:3000` (run with `dspyground dev`)
- Features: Real-time optimization, voice feedback, structured output with Zod
- Metrics: accuracy, tone, efficiency, tool_accuracy, guardrails (customizable)
- Workflow: Chat + Sample → Organize → Optimize → Export prompt
- API keys: `AI_GATEWAY_API_KEY` required, `OPENAI_API_KEY` optional for voice

<!-- AI-CONTEXT-END -->

DSPyGround is a visual prompt optimization playground powered by the GEPA (Genetic-Pareto Evolutionary Algorithm) optimizer. Optional tool installed separately — install via `npm install -g dspyground` when needed.

## Setup

**Prerequisites:** Node.js 18+, npm, `AI_GATEWAY_API_KEY`, `OPENAI_API_KEY` (optional, voice feedback)

```bash
# Install and verify
./.agents/scripts/dspyground-helper.sh install
dspyground --version

# Copy config template
cp configs/dspyground-config.json.txt configs/dspyground-config.json
```

### Project Structure

```text
aidevops/
├── .agents/scripts/dspyground-helper.sh    # Management script
├── configs/dspyground-config.json          # Configuration
└── data/dspyground/[project]/
    ├── dspyground.config.ts                # Project config
    ├── .env                                # API keys
    └── .dspyground/                        # Local data storage
```

## Usage

```bash
# Create project and start dev server (opens http://localhost:3000)
./.agents/scripts/dspyground-helper.sh init my-agent
./.agents/scripts/dspyground-helper.sh dev my-agent
# or from project dir: dspyground dev
```

### Environment (`.env`)

```bash
AI_GATEWAY_API_KEY=your_key_here
OPENAI_API_KEY=${OPENAI_API_KEY}   # optional, for voice feedback
OPENAI_BASE_URL=https://api.openai.com/v1
```

### Project Config (`dspyground.config.ts`)

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

  // Optional: enforce structured output shape
  schema: z.object({
    response: z.string(),
    confidence: z.number().min(0).max(1),
    category: z.enum(['deployment', 'monitoring', 'security', 'general'])
  }),

  preferences: {
    selectedModel: 'openai/gpt-4o-mini',
    optimizationModel: 'openai/gpt-4o-mini',
    reflectionModel: 'openai/gpt-4o',
    batchSize: 3,
    numRollouts: 10,
    selectedMetrics: ['accuracy', 'tone'],
    useStructuredOutput: false,
  },

  metricsPrompt: {
    evaluation_instructions: 'You are an expert DevOps evaluator...',
    dimensions: {
      accuracy:   { name: 'Technical Accuracy',  description: 'Is the advice technically correct?',         weight: 1.0 },
      tone:       { name: 'Professional Tone',    description: 'Is the communication professional?',         weight: 0.8 },
      efficiency: { name: 'Solution Efficiency',  description: 'Does the solution optimize for efficiency?', weight: 0.9 },
    }
  }
}
```

## Optimization Workflow

| Step | Action |
|------|--------|
| 1. Chat + Sample | Converse with agent; save good responses as positive samples, bad as negative |
| 2. Organize | Group samples by use case (e.g., "Deployment Tasks", "Security Questions") |
| 3. Optimize | Click "Optimize" — GEPA runs, shows real-time metrics and candidate prompts |
| 4. Export | Copy best prompt from history; update `dspyground.config.ts`; deploy |

## Metrics

**Built-in:** accuracy, tone, efficiency, tool_accuracy, guardrails

**Custom metrics example:**

```typescript
dimensions: {
  devops_expertise: { name: 'DevOps Expertise', description: 'Deep DevOps knowledge?',   weight: 1.0 },
  actionability:    { name: 'Actionability',    description: 'Can user act immediately?', weight: 0.9 },
}
```

## Advanced Features

### Structured Output

```typescript
schema: z.object({
  task_type: z.enum(['deployment', 'monitoring', 'troubleshooting']),
  priority: z.enum(['low', 'medium', 'high', 'critical']),
  steps: z.array(z.string()),
  estimated_time: z.string(),
  risks: z.array(z.string())
})
```

### Tool Integration

```typescript
tools: {
  deployApp: tool({
    description: 'Deploy application to server',
    parameters: z.object({
      appName: z.string(),
      environment: z.enum(['dev', 'staging', 'prod']),
    }),
    execute: async ({ appName, environment }) => `Deployed ${appName} to ${environment}`,
  }),
}
```

### Voice Feedback

Press and hold spacebar in feedback dialogs to record voice feedback. Automatically transcribed and analysed.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Server won't start | `node --version` (need 18+); `lsof -i :3000` (check port) |
| API key errors | `cat .env`; test: `curl -H "Authorization: Bearer $AI_GATEWAY_API_KEY" https://api.aigateway.com/v1/models` |
| Optimization failures | Reduce `batchSize: 1, numRollouts: 5` in preferences |

## Resources

- [DSPyGround GitHub](https://github.com/Scale3-Labs/dspyground)
- [AI Gateway Docs](https://docs.aigateway.com/)
- [AI SDK Docs](https://sdk.vercel.ai/)
- [GEPA Algorithm Paper](https://arxiv.org/abs/2310.03714)
