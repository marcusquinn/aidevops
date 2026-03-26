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

| Tier | Model | Relative Cost | Best For |
|------|-------|---------------|----------|
| `local` | llama.cpp (user GGUF) | $0 | Privacy/on-device, offline, bulk, experimentation |
| `flash` | gemini-2.5-flash-preview-05-20 | ~0.20x | Large context reads (>50K tokens), summarization, bulk |
| `haiku` | claude-haiku-4-5-20251001 | ~0.25x | Triage, classification, simple transforms, commit messages |
| `composer2` | cursor/composer-2 | ~0.17x | Complex multi-file coding, large refactors (requires Cursor OAuth pool t1549) |
| `sonnet` | claude-sonnet-4-6 | 1x | Code implementation, review, debugging — most dev tasks |
| `pro` | gemini-2.5-pro | ~1.5x | Very large codebases (>100K tokens) + complex reasoning |
| `opus` | claude-opus-4-6 | ~3x | Architecture decisions, novel problems, security audits, complex trade-offs |

**Model ID convention**: Always use fully-qualified IDs (e.g., `claude-sonnet-4-6`, not `claude-sonnet-4`). Short-form names cause `ProviderModelNotFoundError`. Tier names are routing labels resolved at dispatch time — never pass a tier name where a model ID is expected. For CLI flags: `anthropic/claude-sonnet-4-6`, `google/gemini-2.5-pro`.

**Billing**: Subscription plans (Claude Pro/Max, OpenAI Plus/Pro) recommended for regular use. Reserve API keys for testing or burst capacity.

## Routing Rules

| Use | When |
|-----|------|
| `local` | Data must stay on-device; offline; bulk where cost matters; task fits <32K context |
| `flash` | >50K token context; summarization; bulk processing; initial research sweeps |
| `haiku` | Classification/triage; simple text transforms; commit messages; routing decisions |
| `sonnet` | Writing/modifying code; code review; debugging; documentation; most interactive dev |
| `composer2` | Complex multi-file features; large refactors; Cursor pool configured → prefer over sonnet (cheaper + higher quality) |
| `pro` | >100K token codebases; complex reasoning + large context |
| `opus` | Architecture/system design; novel problems; security audits; multi-step plans; evaluating many trade-offs |

**`local` fallback**: Privacy/on-device → FAIL (require `--allow-cloud` to override). Cost optimisation → fall back to `composer2`.

## Decision Flowchart

```text
Privacy/on-device constrained?
  YES → local model running? → YES: local | NO: FAIL (require --allow-cloud)
  NO → bulk/offline saves cost?
    YES → local model running? → YES: local | NO: composer2
    NO → simple classification/formatting? → YES: haiku
         NO → >50K tokens?
           YES → deep reasoning needed? → YES: pro | NO: flash
           NO → novel architecture/design? → YES: opus
                NO → Cursor OAuth pool configured (t1549)? → YES: composer2 | NO: sonnet
```

## Fallback Routing

| Tier | Primary | Fallback | Trigger |
|------|---------|----------|---------|
| `local` | llama.cpp | composer2 (cost) or FAIL (privacy) | Server not running |
| `flash` | gemini-2.5-flash-preview-05-20 | gpt-4.1-mini | No Google key |
| `haiku` | claude-haiku-4-5-20251001 | gemini-2.5-flash-preview-05-20 | No Anthropic key |
| `composer2` | cursor/composer-2 | claude-sonnet-4-6 | No Cursor OAuth pool |
| `sonnet` | claude-sonnet-4-6 | gpt-5.3-codex | No Anthropic key |
| `pro` | gemini-2.5-pro | claude-sonnet-4-6 | No Google key |
| `opus` | claude-opus-4-6 | gpt-5.4 | No Anthropic key |

Supervisor resolves fallbacks automatically during headless dispatch. For interactive sessions, run `compare-models-helper.sh discover` to check availability first.

## Subagent Frontmatter

```yaml
---
model: haiku   # valid: local, composer2, flash, haiku, sonnet, pro, opus
---
```

Absent `model:` → `sonnet`. `local` requires `local-model-helper.sh` setup; falls back to `composer2` if no server running.

## Headless Dispatch Constraints

- **Pulse supervisor**: Anthropic sonnet only — OpenAI models exit immediately without producing activity (proven failure mode). Pin: `PULSE_MODEL=anthropic/claude-sonnet-4-6`.
- **Workers**: Any configured provider. Rotation pool: `AIDEVOPS_HEADLESS_MODELS`.
- **Default** (no env var): `anthropic/claude-sonnet-4-6`.

```bash
export PULSE_MODEL="anthropic/claude-sonnet-4-6"
export AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,openai/gpt-5.3-codex"
```

`AIDEVOPS_HEADLESS_MODELS` is a rotation pool with backoff, not tiered escalation. For guaranteed tier escalation, use `tier:thinking` labels.

## Provider Discovery

```bash
compare-models-helper.sh discover              # Which providers have keys?
compare-models-helper.sh discover --probe      # Verify keys work
compare-models-helper.sh discover --list-models
compare-models-helper.sh discover --json       # Machine-readable
local-model-helper.sh status                   # Local model server status
local-model-helper.sh models                   # Downloaded local models
```

## Model Availability (Pre-Dispatch)

```bash
model-availability-helper.sh check anthropic                    # Provider health (~1-2s, cached 5min)
model-availability-helper.sh check anthropic/claude-sonnet-4-6  # Specific model
model-availability-helper.sh resolve opus                        # Best available for tier
model-availability-helper.sh probe                               # All providers
model-availability-helper.sh status / rate-limits
```

Exit codes: 0=available, 1=unavailable, 2=rate-limited, 3=API-key-invalid. ~4-8x faster than CLI-based probes (direct HTTP to provider `/models` endpoints).

## Model Comparison

```bash
compare-models-helper.sh list
compare-models-helper.sh compare sonnet gpt-4o gemini-pro
compare-models-helper.sh recommend "code review"
compare-models-helper.sh capabilities
```

Interactive: `/compare-models`, `/compare-models-free`, `/route <task>`

## Examples

| Task | Tier | Why |
|------|------|-----|
| Process 1000 log entries locally | local | Bulk, no cloud cost |
| Rename variable across files | haiku | Simple text transform |
| Summarize 200-page PDF | flash | Large context, low reasoning |
| Fix React component bug | sonnet | Code + reasoning |
| Implement auth module across 10 files | composer2 | Frontier coding, multi-file |
| Refactor data layer to Drizzle | composer2 | Complex refactor |
| Review 500-file PR | pro | Large context + reasoning |
| Design auth system architecture | opus | Novel design, trade-offs |
| Generate commit message | haiku | Simple text generation |
| Write unit tests | sonnet | Code generation |
| Evaluate 3 database options | opus | Complex trade-off analysis |

## Bundle-Based Project Presets (t1364.6)

Bundles pre-configure `model_defaults` per project type. Example:

```json
{
  "model_defaults": {
    "implementation": "sonnet",
    "review": "sonnet",
    "triage": "haiku",
    "architecture": "opus",
    "verification": "sonnet",
    "documentation": "haiku"
  }
}
```

**Precedence** (highest wins):
1. Explicit `model:` tag in TODO.md
2. Subagent frontmatter `model:`
3. Bundle `model_defaults`
4. Framework default: `sonnet`

**Composition**: When multiple bundles apply, most-restrictive (highest) tier wins per task type.

**Resolution flow**:
```text
Task dispatched for repo X
  ├── Task has explicit model: tag? → Use it
  ├── Subagent has model: in frontmatter? → Use it
  ├── Repo has bundle? → Look up task type in bundle.model_defaults
  └── Framework default: sonnet
```

```bash
bundle-helper.sh get model_defaults.implementation ~/Git/my-project
bundle-helper.sh resolve ~/Git/my-project
bundle-helper.sh list
```

**Integration**: `cron-dispatch.sh` reads `model_defaults.implementation`; pulse uses `agent_routing`; `linters-local.sh` reads `skip_gates`.

## Failure-Based Escalation (t1416)

After 2 failed worker attempts on the same issue, escalate to the next tier up (typically sonnet → opus). Add `--model anthropic/claude-opus-4-6` to the dispatch command.

**Cost justification**: One opus dispatch (~3x sonnet) costs less than 3+ failed sonnet dispatches. Break-even is 1 failed re-dispatch.

Every dispatch and kill comment MUST include the model tier used — without this, escalation auditing is impossible.

## Tier Drift Detection (t1191)

```bash
/patterns report                              # Full pattern report
/patterns recommend "task type"               # Tier recommendation
budget-tracker-helper.sh tier-drift           # Cost report
budget-tracker-helper.sh tier-drift --json
budget-tracker-helper.sh tier-drift --summary # One-line for automation
```

Supervisor pulse (Phase 12b) checks drift hourly: >25% escalation rate → notice; >50% → warning.

## Prompt Version Tracking (t1396)

```bash
observability-helper.sh record --model claude-sonnet-4-6 \
  --input-tokens 150 --output-tokens 320 \
  --prompt-file prompts/build.txt

compare-models-helper.sh results --prompt-version a1b2c3d
```

<!-- AI-CONTEXT-END -->

## Related

- `tools/local-models/local-models.md` — Local model setup (llama.cpp)
- `tools/local-models/huggingface.md` — Model discovery, GGUF, quantization
- `scripts/local-model-helper.sh` — Local model CLI
- `tools/ai-assistants/compare-models.md` — Full model comparison subagent
- `tools/ai-assistants/models/README.md` — Model-specific subagent definitions
- `scripts/compare-models-helper.sh` — Model comparison and provider discovery
- `scripts/model-registry-helper.sh` — Provider/model registry
- `scripts/commands/route.md` — `/route` command
