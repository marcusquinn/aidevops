---
description: OpenProse DSL for multi-agent orchestration - structured English for AI session control flow
mode: subagent
tools: [read, write, edit, bash, glob, grep, task]
---

# OpenProse - Multi-Agent Orchestration DSL

Use for multi-agent orchestration, repeatable workflows, parallel session spawning, and AI-evaluated conditions. Use aidevops scripts for single-agent DevOps tasks and deterministic logic.

- **Repo**: <https://github.com/openprose/prose>
- **Telemetry**: Disabled by default. Override: `"OPENPROSE_TELEMETRY": "disabled"` in `.prose/state.json` or `--no-telemetry`

**Install:**

```bash
# Claude Code
claude plugin marketplace add https://github.com/openprose/prose.git && claude plugin install open-prose@prose
# OpenCode
git clone https://github.com/openprose/prose.git ~/.config/opencode/skill/open-prose
```

## Syntax

### Sessions & Agents

```prose
session "Do something"
session: myAgent
  prompt: "Task prompt"
  context: previousResult

agent researcher:
  model: sonnet                           # sonnet | opus | haiku
  prompt: "You are a research assistant"
  skills: ["web-search"]
```

### Variables & Context

```prose
let result = session "Get result"         # mutable
const config = session "Get config"       # immutable
session "Use both"
  context: [result, config]               # array form
# or:
session "Use both"
  context: { result, config }             # object form
```

### Parallel Execution

```prose
parallel:                                 # Default: wait for all
  a = session "Task A"
  b = session "Task B"

parallel ("first"):                       # race - first wins
parallel ("any"):                         # first success
parallel (on-fail: "continue"):           # don't abort on failure
parallel (on-fail: "ignore"):             # treat failures as success
```

### Loops

```prose
repeat 3:
  session "Generate idea"

for topic in ["AI", "ML", "DL"]:
  session "Research" context: topic

parallel for item in items:              # fan-out
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

| Tool | Role |
|------|------|
| DSPy | Prompt optimization — optimized prompts work in agent definitions |
| Context7 | Inject library docs into session context |
| TOON | Token-efficient serialization (40-70% fewer tokens) — encode large context before passing between sessions |

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
```

## Related

`overview.md` · `workflows/ralph-loop.md` · `scripts/commands/full-loop.md` · `tools/context/dspy.md` · `tools/context/toon.md` · [Repo](https://github.com/openprose/prose) · [Language Spec](https://github.com/openprose/prose/blob/main/skills/open-prose/docs.md) · [VM Semantics](https://github.com/openprose/prose/blob/main/skills/open-prose/prose.md) · [Examples](https://github.com/openprose/prose/tree/main/examples)
