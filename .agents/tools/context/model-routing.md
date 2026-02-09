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

## Model Tiers

| Tier | Model | Cost | Best For |
|------|-------|------|----------|
| `haiku` | claude-3-5-haiku | Lowest | Triage, classification, simple transforms, formatting |
| `flash` | gemini-2.5-flash | Low | Large context reads, summarization, bulk processing |
| `sonnet` | claude-sonnet-4 | Medium | Code implementation, review, most development tasks |
| `pro` | gemini-2.5-pro | Medium-High | Large codebase analysis, complex reasoning with big context |
| `opus` | claude-opus-4 | Highest | Architecture decisions, complex multi-step reasoning, novel problems |

## Routing Rules

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

Valid values: `haiku`, `flash`, `sonnet`, `pro`, `opus`

When `model:` is absent, `sonnet` is assumed (the default tier).

## Cost Estimation

Approximate relative costs (sonnet = 1x baseline):

| Tier | Input Cost | Output Cost | Relative |
|------|-----------|-------------|----------|
| haiku | 0.25x | 0.25x | ~0.25x |
| flash | 0.15x | 0.30x | ~0.20x |
| sonnet | 1x | 1x | 1x |
| pro | 1.25x | 2.5x | ~1.5x |
| opus | 3x | 3x | ~3x |

## Model-Specific Subagents

Concrete model subagents are defined in `tools/ai-assistants/models/`:

| Tier | Subagent | Primary Model | Fallback |
|------|----------|---------------|----------|
| `haiku` | `models/haiku.md` | claude-3-5-haiku | gemini-2.5-flash |
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

## Fallback Routing

Each tier defines a primary model and a fallback from a different provider. When the primary provider is unavailable (no API key configured, key invalid, or API down), route to the fallback:

| Tier | Primary | Fallback | When to Fallback |
|------|---------|----------|------------------|
| `haiku` | claude-3-5-haiku | gemini-2.5-flash | No Anthropic key |
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
model-availability-helper.sh check anthropic/claude-sonnet-4-20250514

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
Is the task simple classification/formatting?
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
| "Rename variable X to Y across files" | haiku | Simple text transform |
| "Summarize this 200-page PDF" | flash | Large context, low reasoning |
| "Fix this React component bug" | sonnet | Code + reasoning |
| "Review this 500-file PR" | pro | Large context + reasoning |
| "Design the auth system architecture" | opus | Novel design, trade-offs |
| "Generate a commit message" | haiku | Simple text generation |
| "Write unit tests for this module" | sonnet | Code generation |
| "Evaluate 3 database options for our use case" | opus | Complex trade-off analysis |

## Related

- `tools/ai-assistants/compare-models.md` — Full model comparison subagent
- `tools/ai-assistants/models/README.md` — Model-specific subagent definitions
- `scripts/compare-models-helper.sh` — CLI for model comparison and provider discovery
- `scripts/model-registry-helper.sh` — Provider/model registry with periodic sync
- `scripts/commands/route.md` — `/route` command (uses this document's routing rules)
