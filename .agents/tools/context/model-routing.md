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

- **Purpose**: Route tasks to the cheapest model that can handle them well
- **Philosophy**: Use the smallest model that produces acceptable quality
- **Default**: sonnet (best balance of cost/capability for most tasks)
- **Cost spectrum**: local (free) -> haiku -> flash -> sonnet -> pro -> opus (highest)

## Model Tiers

| Tier | Model | Cost | Best For |
|------|-------|------|----------|
| `local` | llama.cpp (user-selected GGUF) | Free ($0) | Privacy-sensitive tasks, offline work, bulk processing, experimentation |
| `haiku` | claude-haiku-4-5 | Lowest | Triage, classification, simple transforms, formatting |
| `flash` | gemini-2.5-flash | Low | Large context reads, summarization, bulk processing |
| `sonnet` | claude-sonnet-4 | Medium | Code implementation, review, most development tasks |
| `pro` | gemini-2.5-pro | Medium-High | Large codebase analysis, complex reasoning with big context |
| `opus` | claude-opus-4 | Highest | Architecture decisions, complex multi-step reasoning, novel problems |

## Routing Rules

### Use `local` when:

- Data must stay on-device (privacy, compliance, air-gapped environments)
- Working offline (no internet after initial model download)
- Bulk processing where per-token cost matters (RAG indexing, embeddings, batch transforms)
- Experimenting with open models (Qwen, Llama, DeepSeek, Mistral, Gemma, Phi)
- Simple tasks where network latency exceeds local inference time
- The task fits within the local model's capability (typically <32K context, simpler reasoning)

**Limitations**: Local models are smaller and less capable than cloud models. Do not route complex reasoning, large-context analysis, or architecture decisions to local.

**Fallback behaviour**: If a local model is not running or not installed, the routing depends on why `local` was selected:

- **Privacy/on-device requirement**: FAIL — do not route to cloud. Return an error instructing the user to start the local server or pass `--allow-cloud` to explicitly override.
- **Cost optimisation or experimentation**: Fall back to `haiku` (cheapest cloud tier).

### Use `haiku` when:

- Classifying or triaging (bug vs feature, priority assignment)
- Simple text transforms (rename, reformat, extract fields)
- Generating commit messages from diffs
- Answering factual questions about code (no reasoning needed)
- Routing decisions (which subagent to use)

### Use `flash` when:

- Reading large files or codebases (>50K tokens of context)
- Summarizing documents, PRs, or discussions
- Bulk processing (many small tasks in sequence)
- Initial research sweeps before deeper analysis

### Use `sonnet` when (default):

- Writing or modifying code
- Code review with actionable feedback
- Debugging with reasoning
- Creating documentation from code
- Most interactive development tasks

### Use `pro` when:

- Analyzing very large codebases (>100K tokens)
- Complex reasoning that also needs large context
- Multi-file refactoring across many files

### Use `opus` when:

- Architecture and system design decisions
- Novel problem-solving (no existing patterns to follow)
- Security audits requiring deep reasoning
- Complex multi-step plans with dependencies
- Evaluating trade-offs with many variables

## Subagent Frontmatter

Add `model:` to subagent YAML frontmatter to declare the recommended tier:

```yaml
---
description: Simple text formatting utility
mode: subagent
model: haiku
tools:
  read: true
---
```

Valid values: `local`, `haiku`, `flash`, `sonnet`, `pro`, `opus`

When `model:` is absent, `sonnet` is assumed (the default tier).

## Cost Estimation

Approximate relative costs (sonnet = 1x baseline):

| Tier | Input Cost | Output Cost | Relative |
|------|-----------|-------------|----------|
| local | 0x | 0x | $0 (electricity only) |
| haiku | 0.25x | 0.25x | ~0.25x |
| flash | 0.15x | 0.30x | ~0.20x |
| sonnet | 1x | 1x | 1x |
| pro | 1.25x | 2.5x | ~1.5x |
| opus | 3x | 3x | ~3x |

## Model-Specific Subagents

Concrete model subagents are defined across these paths (`tools/ai-assistants/models/` for cloud tiers, `tools/local-models/` for the local tier):

| Tier | Subagent | Primary Model | Fallback |
|------|----------|---------------|----------|
| `local` | `tools/local-models/local-models.md` | llama.cpp (user GGUF) | FAIL (privacy) or haiku (cost) |
| `haiku` | `models/haiku.md` | claude-haiku-4-5 | gemini-2.5-flash |
| `flash` | `models/flash.md` | gemini-2.5-flash | gpt-4.1-mini |
| `sonnet` | `models/sonnet.md` | claude-sonnet-4 | gpt-4.1 |
| `pro` | `models/pro.md` | gemini-2.5-pro | claude-sonnet-4 |
| `opus` | `models/opus.md` | claude-opus-4 | o3 |

Cross-provider reviewers: `models/gemini-reviewer.md`, `models/gpt-reviewer.md`

## Integration with Task Tool

When using the Task tool to dispatch subagents, the `model:` field in the subagent's frontmatter serves as a recommendation. The orchestrating agent can override based on task complexity.

For headless dispatch, the supervisor reads `model:` from subagent frontmatter and passes it as the `--model` flag to the CLI.

## Provider Discovery

Before routing to a model, verify the provider is available. The `compare-models-helper.sh discover` command detects configured providers by checking environment variables, gopass secrets, and `credentials.sh`:

```bash
# Quick check: which providers have API keys?
compare-models-helper.sh discover

# Verify keys work by probing provider APIs
compare-models-helper.sh discover --probe

# List live models from each verified provider
compare-models-helper.sh discover --list-models

# Machine-readable output for scripting
compare-models-helper.sh discover --json
```

Discovery checks three sources (in order): environment variables, gopass encrypted secrets, plaintext `credentials.sh`. Use discovery output to constrain routing to models the user can actually access.

For local models, use `local-model-helper.sh status` to check if a local model server is running:

```bash
# Check if local model server is running and which model is loaded
local-model-helper.sh status

# List downloaded local models
local-model-helper.sh models
```

## Fallback Routing

Each tier defines a primary model and a fallback from a different provider. When the primary provider is unavailable (no API key configured, key invalid, or API down), route to the fallback:

| Tier | Primary | Fallback | When to Fallback |
|------|---------|----------|------------------|
| `local` | llama.cpp (localhost) | haiku (cost-only) or FAIL (privacy) | Server not running, no model installed. Fails closed for privacy/on-device tasks; falls back to haiku only for cost-optimisation use cases. |
| `haiku` | claude-haiku-4-5 | gemini-2.5-flash | No Anthropic key |
| `flash` | gemini-2.5-flash | gpt-4.1-mini | No Google key |
| `sonnet` | claude-sonnet-4 | gpt-4.1 | No Anthropic key |
| `pro` | gemini-2.5-pro | claude-sonnet-4 | No Google key |
| `opus` | claude-opus-4 | o3 | No Anthropic key |

The supervisor resolves fallbacks automatically during headless dispatch. For interactive sessions, the orchestrating agent should run `compare-models-helper.sh discover` to check availability before selecting a model.

## Model Comparison

For detailed model comparison (pricing, context windows, capabilities), use the compare-models helper:

```bash
# List all tracked models with pricing
compare-models-helper.sh list

# Compare specific models side-by-side
compare-models-helper.sh compare sonnet gpt-4o gemini-pro

# Get task-specific recommendations
compare-models-helper.sh recommend "code review"

# Show capability matrix
compare-models-helper.sh capabilities
```

Interactive commands: `/compare-models` (with live web fetch), `/compare-models-free` (offline), `/route <task>` (suggest optimal tier).

## Model Registry

The model registry (`model-registry-helper.sh`) maintains a SQLite database tracking all known models across providers. It syncs from subagent frontmatter, embedded pricing data, and live provider APIs. Use `model-registry-helper.sh status` to check registry health and `model-registry-helper.sh check` to verify configured models are available.

## Model Availability (Pre-Dispatch)

The model availability checker (`model-availability-helper.sh`) provides lightweight, cached health probes for use before dispatch. Unlike the model registry (which tracks what models exist), the availability checker tests whether providers are currently responding and API keys are valid.

```bash
# Check if a provider is healthy (fast: direct HTTP, ~1-2s, cached 5min)
model-availability-helper.sh check anthropic

# Check a specific model
model-availability-helper.sh check anthropic/claude-sonnet-4-6

# Resolve best available model for a tier (with automatic fallback)
model-availability-helper.sh resolve opus

# Probe all configured providers
model-availability-helper.sh probe

# View cached status and rate limits
model-availability-helper.sh status
model-availability-helper.sh rate-limits
```

The supervisor uses this automatically during dispatch (t132.3). The availability helper is ~4-8x faster than the previous CLI-based health probe because it calls provider `/models` endpoints directly via HTTP instead of spawning a full AI CLI session.

Exit codes: 0=available, 1=unavailable, 2=rate-limited, 3=API-key-invalid.

<!-- AI-CONTEXT-END -->

## Decision Flowchart

```text
Is the task privacy/on-device constrained?
  → YES: Is a local model running and capable enough?
    → YES: local
    → NO: FAIL (require --allow-cloud to override)
  → NO: Is the task bulk/offline where local saves cost?
    → YES: Is a local model running and capable enough?
      → YES: local
      → NO: haiku (cheapest cloud fallback)
    → NO: Is the task simple classification/formatting?
      → YES: haiku
      → NO: Does it need >50K tokens of context?
        → YES: Is deep reasoning also needed?
          → YES: pro
          → NO: flash
        → NO: Is it a novel architecture/design problem?
          → YES: opus
          → NO: sonnet
```

## Examples

| Task | Recommended | Why |
|------|-------------|-----|
| "Process these 1000 log entries locally" | local | Bulk processing, no cloud cost |
| "Summarize this doc (offline/air-gapped)" | local | No internet available |
| "Quick chat completion (privacy-sensitive)" | local | Data stays on-device |
| "Rename variable X to Y across files" | haiku | Simple text transform |
| "Summarize this 200-page PDF" | flash | Large context, low reasoning |
| "Fix this React component bug" | sonnet | Code + reasoning |
| "Review this 500-file PR" | pro | Large context + reasoning |
| "Design the auth system architecture" | opus | Novel design, trade-offs |
| "Generate a commit message" | haiku | Simple text generation |
| "Write unit tests for this module" | sonnet | Code generation |
| "Evaluate 3 database options for our use case" | opus | Complex trade-off analysis |

## Tier Drift Detection (t1191)

When tasks are requested at one tier but executed at another (e.g., `model:sonnet` in
TODO.md but actually dispatched to opus), this creates cost drift. The framework tracks
this automatically via `requested_tier` and `actual_tier` fields in both the pattern
tracker and budget tracker.

**CLI**:

```bash
# Pattern-based analysis via slash commands
/patterns report                    # Full pattern report
/patterns recommend "task type"     # Tier recommendation from pattern data

# Cost-based analysis (from budget spend events)
budget-tracker-helper.sh tier-drift               # Full cost report
budget-tracker-helper.sh tier-drift --json        # Machine-readable
budget-tracker-helper.sh tier-drift --summary     # One-line for automation
```

**Automatic detection**: The supervisor pulse cycle (Phase 12b) checks tier drift hourly
and logs warnings when escalation rate exceeds 25% (notice) or 50% (warning).

**Data flow**: `dispatch.sh` records `requested_tier`/`actual_tier` to the tasks DB →
`evaluate.sh` reads these and tags pattern entries with `tier_delta:sonnet->opus` →
budget-tracker records spend with both tiers for cost comparison.

## Related

- `tools/local-models/local-models.md` — Local model setup, runtime management (llama.cpp)
- `tools/local-models/huggingface.md` — Model discovery, GGUF format, quantization guidance
- `scripts/local-model-helper.sh` — CLI for local model install, serve, search, cleanup
- `tools/ai-assistants/compare-models.md` — Full model comparison subagent
- `tools/ai-assistants/models/README.md` — Model-specific subagent definitions
- `scripts/compare-models-helper.sh` — CLI for model comparison and provider discovery
- `scripts/model-registry-helper.sh` — Provider/model registry with periodic sync
- `scripts/commands/route.md` — `/route` command (uses this document's routing rules)
