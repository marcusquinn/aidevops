---
description: OpenProse DSL for multi-agent orchestration - structured English for AI session control flow
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

# OpenProse - Multi-Agent Orchestration DSL

**Use OpenProse for**: multi-agent orchestration, repeatable workflows, parallel session spawning, AI-evaluated conditions. Use aidevops scripts for single-agent DevOps tasks and deterministic logic.

- **Repo**: <https://github.com/openprose/prose>
- **Telemetry**: Disabled by default in aidevops. Override: `"OPENPROSE_TELEMETRY": "disabled"` in `.prose/state.json` or `--no-telemetry`

**Install:**

```bash
# Claude Code
claude plugin marketplace add https://github.com/openprose/prose.git
claude plugin install open-prose@prose

# OpenCode
git clone https://github.com/openprose/prose.git ~/.config/opencode/skill/open-prose
```

## Syntax

### Sessions & Agents

```prose
session "Do something"                    # Simple session
session: myAgent                          # With agent
  prompt: "Task prompt"
  context: previousResult

agent researcher:
  model: sonnet                           # sonnet | opus | haiku
  prompt: "You are a research assistant"
  skills: ["web-search"]
```

### Variables & Context

```prose
let result = session "Get result"         # Mutable
const config = session "Get config"       # Immutable
session "Use both"
  context: [result, config]               # Array form
  context: { result, config }             # Object form
```

### Parallel Execution

```prose
parallel:                                 # Default: wait for all
  a = session "Task A"
  b = session "Task B"

parallel ("first"):                       # Race - first wins
parallel ("any"):                         # First success
parallel ("all"):                         # Wait for all (explicit)
parallel (on-fail: "continue"):           # Let all complete
parallel (on-fail: "ignore"):             # Treat failures as success
```

### Loops

```prose
repeat 3:
  session "Generate idea"

for topic in ["AI", "ML", "DL"]:
  session "Research" context: topic

parallel for item in items:              # Fan-out
  session "Process" context: item

loop until **all tests pass** (max: 10):
  session "Fix failing tests"

loop while **there are items to process** (max: 50):
  session "Process next item"
```

### Error Handling

```prose
try:
  session "Risky operation"
    retry: 3
    backoff: "exponential"
catch as err:
  session "Handle error" context: err
finally:
  session "Cleanup"
```

### Conditionals

```prose
if **has security issues**:
  session "Fix security"
elif **has performance issues**:
  session "Optimize"
else:
  session "Approve"

choice **the best approach**:
  option "Quick fix":
    session "Apply quick fix"
  option "Full refactor":
    session "Refactor completely"
```

### Blocks & Pipelines

```prose
block review(target):
  session "Security review" context: target
  session "Performance review" context: target
do review("src/")

let results = items
  | filter:
      session "Keep? yes/no" context: item
  | map:
      session "Transform" context: item
  | reduce(acc, item):
      session "Combine" context: [acc, item]
```

## Integration with aidevops

```text
OpenProse  →  workflow orchestration ("run these agents in parallel, loop until done")
DSPy       →  prompt optimization (optimized prompts work in agent definitions)
Context7   →  library docs  |  Augment → code search  |  LLM-TLDR → summarize
TOON       →  token-efficient serialization (40-70% fewer tokens; encode large context before passing between sessions)
```

## Patterns

### Parallel Code Review

```prose
parallel:
  security = session "Security review"
  perf = session "Performance review"
  style = session "Style review"
session "Synthesize all reviews"
  context: { security, perf, style }
```

### Development Loop with Quality Gates

```prose
agent developer:
  model: opus
  prompt: "You are a senior developer"

loop until **task is complete** (max: 50):
  session: developer
    prompt: "Implement the feature, run tests, fix issues"

parallel:
  lint = session "Run linters and fix issues"
  types = session "Check types and fix issues"
  tests = session "Run tests and fix failures"

if **any checks failed**:
  loop until **all checks pass** (max: 5):
    session "Fix remaining issues"
      context: { lint, types, tests }

let pr = session "Create pull request with gh pr create --fill"

loop until **PR is merged** (max: 20):
  parallel:
    ci = session "Check CI status"
    review = session "Check review status"
  if **CI failed**:
    session "Fix CI issues and push"
  if **changes requested**:
    session "Address review feedback and push"
```

## Related

`overview.md` · `workflows/ralph-loop.md` · `scripts/commands/full-loop.md` · `tools/context/dspy.md` · `tools/context/toon.md`

**Resources**: [Repo](https://github.com/openprose/prose) · [Language Spec](https://github.com/openprose/prose/blob/main/skills/open-prose/docs.md) · [VM Semantics](https://github.com/openprose/prose/blob/main/skills/open-prose/prose.md) · [Examples](https://github.com/openprose/prose/tree/main/examples)
