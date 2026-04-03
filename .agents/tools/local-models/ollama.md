---
description: Ollama local inference provider - setup, context length configuration, OpenCode integration, pulse dispatch
mode: subagent
model: haiku
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Ollama Provider

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Runtime**: Ollama (Go wrapper around llama.cpp, daemon-based)
- **Models**: Any model from the Ollama registry (`ollama pull <model>`)
- **API**: OpenAI-compatible at `http://localhost:11434/v1`
- **Health probe**: `model-availability-helper.sh check ollama`
- **Dispatch**: `opencode run --model ollama/<model> "prompt"` or via pulse with `tier:local`

**CRITICAL: Context length.** Ollama defaults to 4K context. Tool schemas alone consume 4-8K tokens. Agentic loops need 32K+. You MUST configure context length before using Ollama for agent dispatch. See [Context Length Configuration](#context-length-configuration) below.

<!-- AI-CONTEXT-END -->

## When to Use Ollama vs llama.cpp

| Criterion | Ollama | llama.cpp |
|-----------|--------|-----------|
| Setup | `brew install ollama && ollama pull <model>` | Download binary + GGUF, manual flags |
| Daemon | Yes (auto-start, auto-restart) | No (manual process management) |
| Model management | Registry, `ollama pull/rm/list` | Manual GGUF file management |
| Speed | Same engine (llama.cpp underneath) | Same engine |
| Memory management | Auto load/unload, configurable keep-alive | Model stays loaded until killed |
| Control | Abstracted (Modelfile for overrides) | Full flag control |
| Security | Daemon on localhost, no auth | No daemon, localhost only |

**Use Ollama when**: you want zero-config model management, daemon lifecycle, and the pulse dispatch integration. **Use llama.cpp when**: you need full control over inference parameters, bleeding-edge features, or minimal attack surface.

## Installation

```bash
# macOS
brew install ollama

# Linux
curl -fsSL https://ollama.com/install.sh | sh

# Verify
ollama --version
```

Ollama starts automatically as a macOS service after installation.

## Model Setup

```bash
# Pull a model (example: Gemma 4 26B MoE)
ollama pull gemma4:26b

# List loaded models
ollama list

# Test inference
ollama run gemma4:26b "Hello, what model are you?"
```

## Context Length Configuration

This is the most common source of silent failures with Ollama agent dispatch.

### Option A: Environment Variable (Quick)

```bash
# Set before starting ollama serve (or in launchd plist)
export OLLAMA_CONTEXT_LENGTH=65536
ollama serve
```

### Option B: Modelfile (Recommended for Production)

Create a Modelfile that bakes in the context length:

```dockerfile
# ~/.ollama/Modelfile.gemma4-agent
FROM gemma4:26b
PARAMETER num_ctx 65536
PARAMETER temperature 0.1
```

Build and use:

```bash
ollama create gemma4-agent -f ~/.ollama/Modelfile.gemma4-agent
# Now use ollama/gemma4-agent in your config
```

### Option C: Per-Request (API Only)

```bash
curl http://localhost:11434/api/chat -d '{
  "model": "gemma4:26b",
  "options": { "num_ctx": 65536 },
  "messages": [{"role": "user", "content": "Hello"}]
}'
```

Note: The OpenAI-compatible endpoint (`/v1/chat/completions`) does not support `num_ctx` per-request. Use Option A or B for OpenCode/pulse dispatch.

### Memory Budget for Context Length

On Apple Silicon, context length directly affects memory usage via the KV cache:

| Context Length | KV Cache (FP16) | KV Cache (TurboQuant 4-bit) | Total with Q6 Weights (~22GB) |
|---|---|---|---|
| 4K (default) | ~0.5GB | ~0.1GB | ~22.5GB |
| 32K | ~4GB | ~1GB | ~26GB |
| 65K | ~8GB | ~2GB | ~30GB |
| 128K | ~16GB | ~4GB | ~38GB |
| 256K | ~32GB | ~8GB | ~54GB |

**Recommendation for 64GB systems**: 65K context with TurboQuant gives ~30GB total, leaving ample headroom for OS and agent stack.

## OpenCode Provider Configuration

Add to your project's `opencode.json` (or global config):

```json
{
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "http://localhost:11434/v1",
        "timeout": 600000
      },
      "models": {
        "gemma4:26b": {
          "name": "Gemma 4 26B MoE",
          "tool_call": true,
          "attachment": true,
          "reasoning": false,
          "temperature": true,
          "cost": { "input": 0, "output": 0, "cache_read": 0, "cache_write": 0 },
          "limit": { "context": 65536, "output": 8192 }
        }
      }
    }
  }
}
```

Then dispatch with:

```bash
opencode run --model ollama/gemma4:26b "Implement feature X"
```

## Pulse Dispatch

The pulse uses the `local` tier to dispatch to Ollama. The fallback chain is:

```
ollama/auto -> local/llama.cpp -> anthropic/claude-haiku-4-5
```

To force a specific Ollama model, set the GitHub issue label `tier:local` or configure `AIDEVOPS_HEADLESS_MODELS=ollama/gemma4:26b`.

### Health Probe

The pulse checks Ollama health before dispatching:

```bash
# Manual check
model-availability-helper.sh check ollama

# What it validates:
# 1. Server is reachable at localhost:11434
# 2. At least one model is loaded
# 3. Context length >= 16384 (configurable via MIN_OLLAMA_CONTEXT)
```

If the context length check fails, the probe returns `degraded` status and the pulse falls back to the next provider in the chain.

## Troubleshooting

### "Ollama server not reachable"

```bash
# Check if ollama is running
pgrep -f ollama
# Restart
brew services restart ollama
# Or manually
ollama serve
```

### "Context length below minimum"

```bash
# Check current context length
curl -s http://localhost:11434/api/show -d '{"name":"gemma4:26b"}' | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
match = re.search(r'num_ctx\s+(\d+)', data.get('parameters', ''))
print(f'num_ctx: {match.group(1)}' if match else 'num_ctx: 4096 (default)')
"

# Fix: create a Modelfile with proper context length (see above)
```

### "Tool calls not working"

Verify the model supports function calling. Not all Ollama models do. Models with native tool-call support include: Gemma 4, Llama 4, Qwen 3, Mistral Large. Check with:

```bash
ollama show gemma4:26b --modelfile | grep -i tool
```

### Slow inference

On Apple Silicon, inference is memory-bandwidth-bound. Tips:
- Use quantized models (Q4_K_M or Q6_K) — smaller weights = faster inference
- Close memory-heavy apps to reduce memory pressure
- Monitor with `sudo powermetrics --samplers smc -i 1000 -n 1` for thermal throttling
