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

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Structured language for orchestrating multiple AI agent sessions
- **Philosophy**: "The AI session IS the VM" - simulation with sufficient fidelity is implementation
- **Key Feature**: Explicit control flow (`parallel:`, `loop until`, `try/catch`) for multi-agent workflows
- **License**: MIT
- **Repo**: https://github.com/openprose/prose

**When to Use OpenProse**:

| Use OpenProse | Use aidevops Scripts |
|---------------|---------------------|
| Multi-agent orchestration | Single-agent DevOps tasks |
| Repeatable workflows | Ad-hoc operations |
| Parallel session spawning | Sequential execution |
| AI-evaluated conditions | Deterministic logic |

**Installation**:

```bash
# OpenCode
git clone https://github.com/openprose/prose.git ~/.config/opencode/skill/open-prose

# Claude Code
claude plugin marketplace add https://github.com/openprose/prose.git
claude plugin install open-prose@prose
```

<!-- AI-CONTEXT-END -->

## Core Concepts

### 1. The Session as Runtime

OpenProse treats the AI session itself as a virtual machine. When you read the `prose.md` specification, you *become* the OpenProse VM - spawning real subagents via the Task tool, producing real artifacts, and maintaining real state.

### 2. Discretion Markers (`**...**`)

Natural language conditions evaluated by AI judgment:

```prose
loop until **the code is production ready**:
  session "Review and improve the code"
```

The `**...**` syntax signals that the enclosed text should be interpreted semantically, not as a literal boolean.

### 3. Explicit Control Flow

Unlike natural language prompts where control flow is implicit, OpenProse makes it explicit:

```prose
parallel:
  security = session "Security review"
  perf = session "Performance review"
  style = session "Style review"

session "Synthesize all reviews"
  context: { security, perf, style }
```

## Syntax Quick Reference

### Sessions

```prose
session "Do something"                    # Simple session
session: myAgent                          # With agent
  prompt: "Task prompt"
  context: previousResult                 # Pass context
```

### Agents

```prose
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
parallel:
  a = session "Task A"
  b = session "Task B"

# Join strategies
parallel ("first"):     # Race - first wins
parallel ("any"):       # First success
parallel ("all"):       # Wait for all (default)

# Failure policies
parallel (on-fail: "continue"):   # Let all complete
parallel (on-fail: "ignore"):     # Treat failures as success
```

### Loops

```prose
# Fixed iterations
repeat 3:
  session "Generate idea"

# For-each
for topic in ["AI", "ML", "DL"]:
  session "Research" context: topic

# Parallel for-each (fan-out)
parallel for item in items:
  session "Process" context: item

# AI-evaluated condition
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

### Blocks (Reusable Workflows)

```prose
block review(target):
  session "Security review" context: target
  session "Performance review" context: target
  session "Style review" context: target

do review("src/")
do review("tests/")
```

### Pipelines

```prose
let results = items
  | filter:
      session "Keep? yes/no" context: item
  | map:
      session "Transform" context: item
  | reduce(acc, item):
      session "Combine" context: [acc, item]
```

## Integration with aidevops

### Relationship to Existing Tools

OpenProse operates at the **workflow orchestration layer**, complementing our existing optimization stack:

```text
┌─────────────────────────────────────────────────────────────┐
│                    WORKFLOW LAYER                           │
│  OpenProse: "Run these agents in parallel, loop until done" │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    PROMPT LAYER                             │
│  DSPy: "Optimize this prompt for better outputs"            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    CONTEXT LAYER                            │
│  Context7: docs │ Augment: code │ LLM-TLDR: summarize       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    DATA FORMAT LAYER                        │
│  TOON: Serialize data with 40-70% fewer tokens              │
└─────────────────────────────────────────────────────────────┘
```

### Using with DSPy

DSPy-optimized prompts can be used in OpenProse agent definitions:

```prose
agent researcher:
  model: sonnet
  prompt: """
  # DSPy-compiled prompt
  You are a research assistant. When given a topic:
  1. Identify 3 key aspects
  2. For each aspect, find supporting evidence
  3. Synthesize into a coherent summary
  """
```

### Using with TOON

Large context can be TOON-encoded before passing between sessions:

```prose
let raw_data = session "Extract all API endpoints"

# In practice, the AI would compress this
session "Generate API documentation"
  context: raw_data  # Could be TOON-encoded for token efficiency
```

### Using with Context7/Augment

Sessions can leverage our retrieval tools:

```prose
parallel:
  docs = session "Use Context7 to get React hooks documentation"
  code = session "Use Augment to find existing hook implementations"

session "Implement new custom hook following patterns"
  context: { docs, code }
```

## Patterns for Loop Agents

### Parallel Code Review (for `/ralph-loop`)

Instead of sequential reviews, use parallel:

```prose
# Traditional sequential (current ralph-loop)
session "Security review"
session "Performance review"
session "Style review"
session "Synthesize"

# OpenProse parallel pattern
parallel:
  security = session "Security review"
  perf = session "Performance review"
  style = session "Style review"

session "Synthesize all reviews"
  context: { security, perf, style }
```

### Full Loop with Explicit Phases (for `/full-loop`)

```prose
agent developer:
  model: opus
  prompt: "You are a senior developer"

agent reviewer:
  model: sonnet
  prompt: "You are a code reviewer"

# Phase 1: Task Development
loop until **task is complete** (max: 50):
  session: developer
    prompt: "Implement the feature, run tests, fix issues"

# Phase 2: Preflight (parallel quality checks)
parallel:
  lint = session "Run linters and fix issues"
  types = session "Check types and fix issues"
  tests = session "Run tests and fix failures"

if **any checks failed**:
  loop until **all checks pass** (max: 5):
    session "Fix remaining issues"
      context: { lint, types, tests }

# Phase 3: PR Creation
let pr = session "Create pull request with gh pr create --fill"

# Phase 4: PR Review Loop
loop until **PR is merged** (max: 20):
  parallel:
    ci = session "Check CI status"
    review = session "Check review status"
  
  if **CI failed**:
    session "Fix CI issues and push"
  
  if **changes requested**:
    session "Address review feedback and push"

# Phase 5: Postflight
session "Verify release health"
```

### Postflight Monitoring Pattern

```prose
loop until **release is healthy** (max: 10):
  parallel:
    ci = session "Check GitHub Actions status"
    tag = session "Verify release tag exists"
    version = session "Check VERSION file matches"
  
  if **any check failed**:
    session "Report issues and wait 30 seconds"
  else:
    session "All checks passing"
```

## Narration Protocol

When executing OpenProse programs, use emoji markers for state tracking:

| Emoji | Category | Usage |
|-------|----------|-------|
| `📋` | Program | Start, end, definition collection |
| `📍` | Position | Current statement being executed |
| `📦` | Binding | Variable assignment or update |
| `✅` | Success | Session or block completion |
| `⚠️` | Error | Failures and exceptions |
| `🔀` | Parallel | Entering, branch status, joining |
| `🔄` | Loop | Iteration, condition evaluation |

Example trace:

```text
📋 Program Start
📍 Statement 1: parallel block
🔀 Entering parallel (3 branches, strategy: all)
   [Task: "Security review"] [Task: "Performance review"] [Task: "Style review"]
🔀 Parallel complete:
   - security = "No vulnerabilities found..."
   - perf = "Performance is acceptable..."
   - style = "Code follows conventions..."
📦 security, perf, style bound
📍 Statement 2: session "Synthesize"
✅ Session complete
📋 Program Complete
```

## When to Use OpenProse vs Native aidevops

| Scenario | Recommendation |
|----------|----------------|
| Simple single-agent task | Use native aidevops (scripts, workflows) |
| Multi-agent parallel work | Use OpenProse `parallel:` blocks |
| Complex conditional logic | Use OpenProse `if`/`choice` blocks |
| Iterative refinement | Use OpenProse `loop until **condition**` |
| Error recovery workflows | Use OpenProse `try/catch/retry` |
| Reusable workflow templates | Use OpenProse `block` definitions |
| Quick one-off operations | Use native aidevops |

## Examples

### Example 1: Parallel Research

```prose
agent researcher:
  model: sonnet
  skills: ["web-search"]

parallel:
  market = session: researcher
    prompt: "Research market trends"
  tech = session: researcher
    prompt: "Research technology landscape"
  competition = session: researcher
    prompt: "Analyze competitors"

session "Write comprehensive report"
  context: { market, tech, competition }
```

### Example 2: Code Review Pipeline

```prose
# Define reviewers
agent security_reviewer:
  model: opus
  prompt: "You are a security expert. Look for vulnerabilities."

agent perf_reviewer:
  model: sonnet
  prompt: "You are a performance expert. Look for bottlenecks."

# Parallel review
parallel:
  sec = session: security_reviewer
    prompt: "Review src/ for security issues"
  perf = session: perf_reviewer
    prompt: "Review src/ for performance issues"

# Synthesize
session "Create unified review report"
  context: { sec, perf }
```

### Example 3: Iterative Bug Fixing

```prose
loop until **all tests pass** (max: 20) as attempt:
  let test_result = session "Run test suite"
  
  if **tests failed**:
    session "Analyze failures and fix bugs"
      context: test_result
  else:
    session "All tests passing!"
```

## Related Documentation

| Document | Purpose |
|----------|---------|
| `overview.md` | AI orchestration framework comparison |
| `workflows/ralph-loop.md` | Ralph loop technique |
| `scripts/commands/full-loop.md` | Full development loop |
| `tools/context/dspy.md` | Prompt optimization |
| `tools/context/toon.md` | Token-efficient serialization |

## Resources

- **Repository**: https://github.com/openprose/prose
- **Language Spec**: https://github.com/openprose/prose/blob/main/skills/open-prose/docs.md
- **VM Semantics**: https://github.com/openprose/prose/blob/main/skills/open-prose/prose.md
- **Examples**: https://github.com/openprose/prose/tree/main/examples
