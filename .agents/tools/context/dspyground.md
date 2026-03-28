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

## Setup

DSPyGround is an optional tool installed separately from the aidevops CLI.

```bash
# Install
./.agents/scripts/dspyground-helper.sh install

# Configure (copy template, then edit)
cp configs/dspyground-config.json.txt configs/dspyground-config.json

# Initialize a project and start dev server (opens http://localhost:3000)
./.agents/scripts/dspyground-helper.sh init my-agent
./.agents/scripts/dspyground-helper.sh dev my-agent
```

**Project layout:**

```text
data/dspyground/[project-name]/
├── dspyground.config.ts   # Project configuration
├── .env                   # Environment variables
└── .dspyground/           # Local data storage
```

## Configuration

### dspyground.config.ts

```typescript
import { tool } from 'ai'
import { z } from 'zod'

export default {
  systemPrompt: `You are a helpful DevOps assistant...`,

  // AI SDK tools (optional)
  tools: {
    checkServerStatus: tool({
      description: 'Check the status of a server',
      parameters: z.object({ serverId: z.string().describe('The server ID to check') }),
      execute: async ({ serverId }) => `Server ${serverId} is running normally`,
    }),
  },

  // Optional: enforce structured output
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
      accuracy:   { name: 'Technical Accuracy',  description: 'Is the DevOps advice technically correct?',          weight: 1.0 },
      tone:       { name: 'Professional Tone',    description: 'Is the communication professional and clear?',       weight: 0.8 },
      efficiency: { name: 'Solution Efficiency',  description: 'Does the solution optimize for efficiency?',         weight: 0.9 },
    }
  }
}
```

### .env

```bash
AI_GATEWAY_API_KEY=your_ai_gateway_api_key_here   # Required
OPENAI_API_KEY=${OPENAI_API_KEY}                   # Optional — voice feedback
OPENAI_BASE_URL=https://api.openai.com/v1
```

DSPyGround inherits API keys from the terminal session environment; only `AI_GATEWAY_API_KEY` needs explicit configuration when using AI Gateway.

## Optimization Workflow

1. **Chat + Sample** — run conversations, save good responses as positive samples, mark bad ones negative
2. **Organize** — group samples by use case (e.g., "Deployment Tasks", "Security Questions")
3. **Optimize** — click Optimize; GEPA runs, shows real-time Pareto frontier and metric evolution
4. **Export** — copy the winning prompt from history into `dspyground.config.ts`, deploy

## Metrics

Built-in: `accuracy`, `tone`, `efficiency`, `tool_accuracy`, `guardrails`.

Custom dimensions example:

```typescript
metricsPrompt: {
  dimensions: {
    devops_expertise: { name: 'DevOps Expertise', description: 'Deep DevOps knowledge?',              weight: 1.0 },
    actionability:    { name: 'Actionability',     description: 'Can the user act on this immediately?', weight: 0.9 },
  }
}
```

## Advanced Features

**Voice feedback** — press and hold spacebar in feedback dialogs; auto-transcribed.

**Structured output** — enforce a Zod schema on agent responses:

```typescript
schema: z.object({
  task_type: z.enum(['deployment', 'monitoring', 'troubleshooting']),
  priority: z.enum(['low', 'medium', 'high', 'critical']),
  steps: z.array(z.string()),
  estimated_time: z.string(),
  risks: z.array(z.string())
})
```

**Tool integration** — wire real deployment systems via AI SDK `tool()`:

```typescript
tools: {
  deployApp: tool({
    description: 'Deploy application to server',
    parameters: z.object({ appName: z.string(), environment: z.enum(['dev', 'staging', 'prod']) }),
    execute: async ({ appName, environment }) => `Deployed ${appName} to ${environment}`,
  }),
}
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Server won't start | `node --version` (need 18+); `lsof -i :3000` to check port conflict |
| API key errors | `cat .env`; test with `curl -H "Authorization: Bearer $AI_GATEWAY_API_KEY" https://api.aigateway.com/v1/models` |
| Optimization failures | Reduce `batchSize: 1, numRollouts: 5` in preferences |

## Resources

- [DSPyGround GitHub](https://github.com/Scale3-Labs/dspyground)
- [AI Gateway Docs](https://docs.aigateway.com/)
- [AI SDK Docs](https://sdk.vercel.ai/)
- [GEPA Algorithm Paper](https://arxiv.org/abs/2310.03714)
- [AI DevOps Framework Overview](../README.md)
