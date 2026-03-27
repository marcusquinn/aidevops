---
description: Cost-aware model routing - match task complexity to optimal model tier
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
model: haiku
---

# Cost-Aware Model Routing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Default**: `sonnet` (best cost/capability balance)
- **Cost spectrum**: local (free) → composer2 → flash → haiku → sonnet → pro → opus
- **Rule**: use the smallest model that produces acceptable quality

## Model Tiers

| Tier | Model | Cost | Use When |
|------|-------|------|----------|
| `local` | llama.cpp (user GGUF) | $0 | Privacy/on-device, offline, bulk, experimentation; <32K context |
| `composer2` | cursor/composer-2 | ~0.17x | Complex multi-file coding, large refactors (requires Cursor OAuth pool t1549) |
| `flash` | gemini-2.5-flash-preview-05-20 | ~0.20x | >50K token context, summarization, bulk processing, research sweeps |
| `haiku` | claude-haiku-4-5-20251001 | ~0.25x | Classification/triage, simple transforms, commit messages, routing decisions |
| `sonnet` | claude-sonnet-4-6 | 1x | Code implementation, review, debugging, documentation — most dev tasks |
| `pro` | gemini-2.5-pro | ~1.5x | >100K token codebases + complex reasoning |
| `opus` | claude-opus-4-6 | ~3x | Architecture, novel problems, security audits, complex trade-offs |

**Model IDs**: Always fully-qualified (e.g., `claude-sonnet-4-6`, not `claude-sonnet-4`). Short-form causes `ProviderModelNotFoundError`. CLI: `anthropic/claude-sonnet-4-6`, `google/gemini-2.5-pro`.

**`local` fallback**: Privacy → FAIL (require `--allow-cloud`). Cost → fall back to `composer2`.

**Billing**: Subscription plans recommended for regular use. API keys for testing/burst.

## Decision Flowchart

```text
Privacy/on-device? → YES → local running? → YES: local | NO: FAIL
  NO → bulk/offline? → YES → local running? → YES: local | NO: composer2
    NO → simple classification? → YES: haiku
      NO → >50K tokens? → YES → deep reasoning? → YES: pro | NO: flash
        NO → novel architecture? → YES: opus
          NO → Cursor pool (t1549)? → YES: composer2 | NO: sonnet
```

## Fallback Routing

| Tier | Primary | Fallback | Trigger |
|------|---------|----------|---------|
| `local` | llama.cpp | composer2 (cost) / FAIL (privacy) | Server not running |
| `flash` | gemini-2.5-flash-preview-05-20 | gpt-4.1-mini | No Google key |
| `haiku` | claude-haiku-4-5-20251001 | gemini-2.5-flash-preview-05-20 | No Anthropic key |
| `composer2` | cursor/composer-2 | claude-sonnet-4-6 | No Cursor OAuth pool |
| `sonnet` | claude-sonnet-4-6 | gpt-5.3-codex | No Anthropic key |
| `pro` | gemini-2.5-pro | claude-sonnet-4-6 | No Google key |
| `opus` | claude-opus-4-6 | gpt-5.4 | No Anthropic key |

Supervisor resolves fallbacks automatically. Interactive: `compare-models-helper.sh discover`.

## Subagent Frontmatter

Set `model: haiku` (or any tier) in YAML frontmatter. Absent → `sonnet`. `local` requires `local-model-helper.sh`; falls back to `composer2`.

## Headless Dispatch

- **Pulse supervisor**: Anthropic sonnet only — OpenAI models exit without activity (proven). Pin: `PULSE_MODEL=anthropic/claude-sonnet-4-6`.
- **Workers**: Any provider. `AIDEVOPS_HEADLESS_MODELS` is rotation with backoff, not escalation. For tier escalation, use `tier:thinking` labels.
- **Default**: `anthropic/claude-sonnet-4-6`.

```bash
export PULSE_MODEL="anthropic/claude-sonnet-4-6"
export AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,openai/gpt-5.3-codex"
```

## CLI Tools

```bash
compare-models-helper.sh discover [--probe|--list-models|--json]
local-model-helper.sh status|models
model-availability-helper.sh check anthropic|anthropic/claude-sonnet-4-6
model-availability-helper.sh resolve opus|probe|status|rate-limits
# Exit: 0=available, 1=unavailable, 2=rate-limited, 3=invalid-key
compare-models-helper.sh list|capabilities|compare|recommend "task"
```

Interactive: `/compare-models`, `/compare-models-free`, `/route <task>`

## Bundle Presets (t1364.6)

Bundles pre-configure `model_defaults` per project type:

```json
{ "model_defaults": { "implementation": "sonnet", "review": "sonnet", "triage": "haiku",
    "architecture": "opus", "verification": "sonnet", "documentation": "haiku" } }
```

**Precedence** (highest wins): (1) `model:` in TODO.md, (2) subagent frontmatter, (3) bundle `model_defaults`, (4) default `sonnet`. Multiple bundles → most-restrictive tier wins.

```bash
bundle-helper.sh get model_defaults.implementation ~/Git/my-project
bundle-helper.sh resolve ~/Git/my-project
```

Integration: `cron-dispatch.sh` reads `model_defaults.implementation`; pulse uses `agent_routing`; `linters-local.sh` reads `skip_gates`.

## Failure-Based Escalation (t1416)

After 2 failed attempts, escalate to next tier (sonnet → opus via `--model anthropic/claude-opus-4-6`). One opus (~3x) costs less than 3+ failed sonnet dispatches. Every dispatch/kill comment MUST include model tier for escalation auditing.

## Tier Drift Detection (t1191)

```bash
/patterns report|recommend "task type"
budget-tracker-helper.sh tier-drift [--json|--summary]
```

Pulse Phase 12b checks hourly: >25% escalation → notice; >50% → warning.

## Prompt Version Tracking (t1396)

```bash
observability-helper.sh record --model claude-sonnet-4-6 \
  --input-tokens 150 --output-tokens 320 --prompt-file prompts/build.txt
compare-models-helper.sh results --prompt-version a1b2c3d
```

<!-- AI-CONTEXT-END -->

## Related

- `tools/local-models/local-models.md` — Local model setup (llama.cpp)
- `tools/ai-assistants/compare-models.md` — Full model comparison subagent
- `scripts/compare-models-helper.sh` — Provider discovery and comparison
- `scripts/commands/route.md` — `/route` command
