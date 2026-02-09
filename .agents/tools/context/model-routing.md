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
