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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cost-Aware Model Routing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Default**: `sonnet`. **Rule**: smallest model that produces acceptable quality.
- **Spectrum**: local ($0) → composer2 (0.17x) → flash (0.20x) → haiku (0.25x) → sonnet (1x) → pro (1.5x) → opus (3x)
- **Frontmatter**: `model: haiku` in YAML. Absent → `sonnet`. `local` requires `local-model-helper.sh`; falls back to `composer2`.

## Model Tiers

| Tier | Model | Use When |
|------|-------|----------|
| `local` | llama.cpp or Ollama (user models) | Privacy/offline, bulk, experimentation; opt-in only |
| `composer2` | cursor/composer-2 | Multi-file coding, large refactors (requires Cursor OAuth pool t1549) |
| `flash` | gemini-2.5-flash-preview-05-20 | >50K context, summarization, bulk processing, research sweeps |
| `haiku` | claude-haiku-4-5-20251001 | Classification, triage, simple transforms, commit messages, routing |
| `sonnet` | claude-sonnet-4-6 | Code, review, debugging, docs — most dev tasks |
| `pro` | gemini-2.5-pro | >100K codebases + complex reasoning |
| `opus` | claude-opus-4-6 | Architecture, novel problems, security audits, complex trade-offs |

**Model IDs**: Always fully-qualified (`claude-sonnet-4-6`, not `claude-sonnet-4`). Short-form → `ProviderModelNotFoundError`. CLI prefix: `anthropic/`, `google/`.

**`local` fallback**: Privacy → FAIL (require `--allow-cloud`). Cost → Ollama → `composer2`. Local is opt-in only — default dispatch uses `haiku`. Users who explicitly configure local tier: llama.cpp → Ollama → `haiku`.

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

| Tier | Fallback | Trigger |
|------|----------|---------|
| `local` | Ollama → composer2 (cost) / FAIL (privacy) | llama.cpp not running |
| `flash` | gpt-4.1-mini | No Google key |
| `haiku` | flash | No Anthropic key |
| `composer2` | sonnet | No Cursor OAuth pool |
| `sonnet` | gpt-5.3-codex | No Anthropic key |
| `pro` | sonnet | No Google key |
| `opus` | gpt-5.4 | No Anthropic key |

Supervisor resolves automatically. Interactive: `compare-models-helper.sh discover`.

## Headless Dispatch

**Automatic model derivation (GH#17769):** Headless routing is derived at runtime — no model-ID env var configuration needed:

1. **Routing table** (`configs/model-routing-table.json`, or local override at `custom/configs/model-routing-table.json`) → ordered models per tier
2. **Provider filter** (`AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`) → optional local pinning such as `openai`
3. **Auth + availability checks** (`headless-runtime-helper.sh`, `model-availability-helper.sh`) → providers/models that can actually run now
4. **Result**: pulse resolves a sonnet-tier model; workers round-robin across the filtered sonnet-tier list

- **Shared default**: The framework routing table remains Anthropic-first. Other providers are opt-in through `custom/configs/model-routing-table.json`, so existing Anthropic users are unchanged after update.
- **Pulse**: Resolves `sonnet` through `model-availability-helper.sh resolve sonnet`, so it follows routing-table order, health checks, local routing-table overrides, and `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`.
- **Workers**: Round-robin across the routed `sonnet` models after allowlist filtering and auth checks. Tier escalation still uses `resolve` (`tier:simple` → `haiku`, `tier:standard` → `sonnet`, `tier:thinking` → `opus`).
- **Local switch**: Add OpenAI models to `custom/configs/model-routing-table.json`, then set `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai` to force both pulse and workers onto OpenAI. If you want OpenAI primary but Anthropic fallback, reorder the custom routing table and omit the allowlist.
- **Reasoning effort**: OpenCode exposes GPT reasoning variants separately (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`). Headless runs do not default to `xhigh`; if no variant is set, OpenCode sends no explicit effort override and the provider default applies.
- **Tier-aware effort**: Headless dispatch can now apply variants by resolved tier. `AIDEVOPS_HEADLESS_VARIANT_SONNET=high` and `AIDEVOPS_HEADLESS_VARIANT_OPUS=xhigh` make standard work run at `high` and reasoning-tier work run at `xhigh` even when both tiers use `openai/gpt-5.4`.
- **Fallback**: If routed resolution fails entirely, pulse falls back to `anthropic/claude-sonnet-4-6`; workers fall back to `DEFAULT_HEADLESS_MODELS` when no allowlist is forcing a subset.
- **Deprecated**: `PULSE_MODEL` and `AIDEVOPS_HEADLESS_MODELS` env vars are respected as overrides for one release cycle with deprecation warnings. Remove from `credentials.sh`.

### Per-user override that survives auto-update

Auto-update overwrites `~/.aidevops/agents/configs/*.json` and `~/.aidevops/agents/scripts/*`, so user-specific routing must live outside those paths.

- Put persistent model-order overrides in `~/.aidevops/agents/custom/configs/model-routing-table.json`
- Put the provider pin in `~/.config/aidevops/credentials.sh`

Example custom override for OpenAI-capable headless routing:

```json
{
  "tiers": {
    "sonnet": { "models": ["openai/gpt-5.4", "anthropic/claude-sonnet-4-6"] },
    "opus": { "models": ["openai/gpt-5.4", "anthropic/claude-opus-4-6"] }
  }
}
```

Example hard pin:

```bash
export AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="openai"
```

Example reasoning effort override:

```bash
export AIDEVOPS_HEADLESS_VARIANT_SONNET="high"
export AIDEVOPS_HEADLESS_VARIANT_OPUS="xhigh"
```

Role-specific overrides still exist when needed:

```bash
export AIDEVOPS_HEADLESS_PULSE_VARIANT="high"
export AIDEVOPS_HEADLESS_WORKER_VARIANT="xhigh"
```

## CLI Tools

```bash
compare-models-helper.sh discover [--probe|--list-models|--json]
compare-models-helper.sh list|capabilities|compare|recommend "task"
local-model-helper.sh status|models
model-availability-helper.sh check|resolve  # Exit: 0=ok, 1=unavail, 2=rate-limited, 3=bad-key
```

Interactive: `/compare-models`, `/compare-models-free`, `/route <task>`

## Bundle Presets (t1364.6)

```json
{ "model_defaults": { "implementation": "sonnet", "review": "sonnet", "triage": "haiku",
    "architecture": "opus", "verification": "sonnet", "documentation": "haiku" } }
```

**Precedence** (highest wins): `model:` in TODO.md → subagent frontmatter → bundle `model_defaults` → default `sonnet`. Multiple bundles → most-restrictive tier wins. CLI: `bundle-helper.sh get|resolve`. Integration: `cron-dispatch.sh`, pulse `agent_routing`, `linters-local.sh` `skip_gates`.

## Failure-Based Escalation (t1416 + GH#14964)

After 2 failed attempts, escalate to next tier (sonnet → opus via `--model anthropic/claude-opus-4-6`). One opus (~3x) < 3+ failed sonnet dispatches. Dispatch/kill comments MUST include model tier for escalation auditing.

**Worker BLOCKED policy (GH#14964 — MANDATORY):** Attempt model escalation before exiting `BLOCKED`. Review-policy metadata, nominal GitHub states, and lower-tier model limits are NOT valid blockers on their own — a genuine blocker must persist after escalation. See `prompts/worker-efficiency-protocol.md` "Model escalation before BLOCKED".

## Tier Drift Detection (t1191)

`budget-tracker-helper.sh tier-drift [--json|--summary]` or `/patterns report|recommend "task type"`. Pulse Phase 12b checks hourly: >25% escalation → notice; >50% → warning.

## Prompt Version Tracking (t1396)

`observability-helper.sh record --model <id> --input-tokens N --output-tokens N --prompt-file <path>`. Results: `compare-models-helper.sh results --prompt-version <hash>`.

<!-- AI-CONTEXT-END -->

## Related

- `tools/local-models/local-models.md` — Local model setup (llama.cpp)
- `tools/ai-assistants/compare-models.md` — Full model comparison subagent
- `scripts/compare-models-helper.sh` — Provider discovery and comparison
- `scripts/commands/route.md` — `/route` command
