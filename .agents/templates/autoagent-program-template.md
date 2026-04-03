---
name: {program-name}
mode: in-repo
target_repo: .
---

# Autoagent: {Title}

<!-- AI-CONTEXT-START -->

An autoagent research program defines what the framework self-improvement loop
optimizes, which signals it mines, which hypothesis types it uses, what safety
constraints apply, and how it evaluates changes.

Fields marked `# required` must be present. Fields marked `# optional` may be omitted.

The autoagent subagent reads this file at session start and uses it as the
contract for the entire experiment loop. Unlike the base research-program-template,
this template adds autoagent-specific sections: Signal Sources, Hypothesis Types,
Safety, and multi-trial Evaluation.

<!-- AI-CONTEXT-END -->

## Target

```text
files: {glob patterns of modifiable files, comma-separated}   # required
branch: experiment/autoagent-{name}                            # auto-generated if omitted
```

Examples:

- `files: .agents/scripts/*.sh` — all helper scripts
- `files: .agents/**/*.md` — all agent docs
- `files: .agents/prompts/build.txt, .agents/**/*.md` — multiple patterns

## Signal Sources

```text
session_miner: true     # mine session-miner-pulse.sh output for error patterns
comprehension: true     # run agent-test-helper.sh and analyze failures
linters: true           # run linters and count violations
git_churn: true         # identify high-churn framework files
pulse_outcomes: false   # mine pulse dispatch success/failure (requires pulse history)
```

At least one signal source must be `true`. Signal sources inform hypothesis generation —
the autoagent reads signal output before proposing each experiment.

## Hypothesis Types

```text
self_healing: true          # fix recurring failures from session logs
tool_optimization: true     # improve existing helper scripts
instruction_refinement: true # optimize agent docs for clarity/tokens
tool_creation: false        # propose new tools (higher risk)
agent_composition: false    # restructure subagent routing
workflow_optimization: false # modify operational patterns
```

At least one hypothesis type must be `true`. Higher-risk types (`tool_creation`,
`agent_composition`, `workflow_optimization`) should only be enabled after lower-risk
types have been exhausted or in elevated-safety programs with 3+ trials.

## Safety

```text
level: standard             # standard | elevated
never_modify: []            # additional files beyond default never-modify list
require_review: []          # files that need manual review before keep
```

**Standard safety** (default): never modifies root `AGENTS.md` (developer/contributor
guide), `prompts/build.txt`, `configs/*.json`, or any file containing credentials.
`.agents/AGENTS.md` (user/operational guide) is also protected by default.

**Elevated safety**: may touch root `AGENTS.md` and `prompts/build.txt` non-security
sections. Requires `trials: 3` minimum and explicit `level: elevated` declaration.
Use only for overnight programs with full signal coverage.

## Metric

```text
command: autoagent-metric-helper.sh score     # required
name: composite_score                          # required
direction: higher                              # required: lower | higher
baseline: null                                 # auto-populated on first run
goal: null                                     # optional: stop when reached
weights: "0.6,0.3,0.1"                        # optional: comprehension,lint,tokens
```

The default `autoagent-metric-helper.sh score` command outputs a composite score
(0.0–1.0) weighted across comprehension pass rate, lint cleanliness, and token
efficiency. Override `weights` to shift emphasis.

Custom metric commands must:

- Exit 0 on success
- Print exactly one number to stdout (the subagent parses the last line)
- Be deterministic enough to distinguish signal from noise

## Constraints

Each constraint is a shell command that must exit 0 before the metric is measured.
The autoagent runs all constraints after each modification. Failure = discard the experiment.

```text
- Tests must pass: autoagent-metric-helper.sh comprehension | awk '{exit ($1 < 0.8)}'
- Lint clean: autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'
- ShellCheck: find .agents/scripts -name '*.sh' -exec shellcheck {} \;
```

## Models

```text
researcher: sonnet     # required: model that runs the experiment loop
```

Model tiers: `haiku` (fast/cheap), `sonnet` (balanced), `opus` (best quality).
Use `sonnet` for most programs. Reserve `opus` for full-autonomous overnight runs
where hypothesis quality matters more than cost.

## Budget

```text
timeout: 7200          # required: total wall-clock seconds
max_iterations: 30     # required: max experiment count
per_experiment: 300    # optional: max seconds per single experiment (default: 5min)
trials: 2              # optional: repeat each experiment N times for consistency (default: 1)
```

**Trials**: running each experiment multiple times filters out noise. A change is
only kept if it improves the metric in `ceil(trials/2)` or more runs. Higher trial
counts increase confidence but multiply runtime cost.

## Hints

Optional human guidance for the researcher model's hypothesis generation.
The autoagent reads these before generating each hypothesis.

- {hint about where to look for improvements}
- {hint about what approaches to avoid}
- {hint about known constraints or gotchas}

---

## Examples

The following are complete, runnable autoagent programs. Copy and adapt.

---

### Example 1: Self-Healing Focus

```markdown
---
name: self-healing-focus
mode: in-repo
target_repo: .
---

# Autoagent: Self-Healing — Fix Recurring Session Errors

## Target

\`\`\`text
files: .agents/scripts/*.sh, .agents/workflows/*.md
branch: experiment/autoagent-self-healing
\`\`\`

## Signal Sources

\`\`\`text
session_miner: true
comprehension: false
linters: true
git_churn: true
pulse_outcomes: false
\`\`\`

## Hypothesis Types

\`\`\`text
self_healing: true
tool_optimization: true
instruction_refinement: false
tool_creation: false
agent_composition: false
workflow_optimization: false
\`\`\`

## Safety

\`\`\`text
level: standard
never_modify: []
require_review: []
\`\`\`

## Metric

\`\`\`text
command: autoagent-metric-helper.sh score
name: composite_score
direction: higher
baseline: null
goal: null
weights: "0.6,0.3,0.1"
\`\`\`

## Constraints

\`\`\`text
- Tests must pass: autoagent-metric-helper.sh comprehension | awk '{exit ($1 < 0.8)}'
- Lint clean: autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'
- ShellCheck: find .agents/scripts -name '*.sh' -exec shellcheck {} \;
\`\`\`

## Models

\`\`\`text
researcher: sonnet
\`\`\`

## Budget

\`\`\`text
timeout: 3600
max_iterations: 15
per_experiment: 300
trials: 2
\`\`\`

## Hints

- Check error-feedback patterns for recurring failures first
- Priority: fix errors that occur in >10% of sessions
- Prefer adding validation/guards over rewriting logic
- ShellCheck violations in helper scripts are high-signal targets
- Git churn identifies scripts that change frequently — likely fragile
```

---

### Example 2: Instruction Refinement

```markdown
---
name: instruction-refinement
mode: in-repo
target_repo: .
---

# Autoagent: Instruction Refinement — Optimize Agent Docs for Clarity and Tokens

## Target

\`\`\`text
files: .agents/**/*.md, .agents/prompts/*.txt
branch: experiment/autoagent-instruction-refinement
\`\`\`

## Signal Sources

\`\`\`text
session_miner: false
comprehension: true
linters: true
git_churn: false
pulse_outcomes: false
\`\`\`

## Hypothesis Types

\`\`\`text
self_healing: false
tool_optimization: false
instruction_refinement: true
tool_creation: false
agent_composition: false
workflow_optimization: false
\`\`\`

## Safety

\`\`\`text
level: standard
never_modify: []
require_review: [".agents/prompts/build.txt"]
\`\`\`

## Metric

\`\`\`text
command: autoagent-metric-helper.sh score
name: composite_score
direction: higher
baseline: null
goal: null
weights: "0.4,0.2,0.4"
\`\`\`

## Constraints

\`\`\`text
- Tests must pass: autoagent-metric-helper.sh comprehension | awk '{exit ($1 < 0.8)}'
- Lint clean: autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'
- Markdownlint: markdownlint-cli2 ".agents/**/*.md"
\`\`\`

## Models

\`\`\`text
researcher: sonnet
\`\`\`

## Budget

\`\`\`text
timeout: 7200
max_iterations: 30
per_experiment: 300
trials: 2
\`\`\`

## Hints

- Redundant rules across files are the primary token waste
- Merge thin sections covering the same topic
- Never remove security instructions or traceability requirements
- Shorter phrasing that preserves meaning is always a win
- Comprehension test failures reveal which instructions are unclear — fix those first
- weights "0.4,0.2,0.4" emphasizes token reduction equally with comprehension
```

---

### Example 3: Full Autonomous (Overnight)

```markdown
---
name: full-autonomous-overnight
mode: in-repo
target_repo: .
---

# Autoagent: Full Autonomous — All Hypothesis Types, All Signal Sources

## Target

\`\`\`text
files: .agents/**/*.md, .agents/scripts/*.sh, .agents/prompts/*.txt
branch: experiment/autoagent-full-autonomous
\`\`\`

## Signal Sources

\`\`\`text
session_miner: true
comprehension: true
linters: true
git_churn: true
pulse_outcomes: true
\`\`\`

## Hypothesis Types

\`\`\`text
self_healing: true
tool_optimization: true
instruction_refinement: true
tool_creation: true
agent_composition: true
workflow_optimization: true
\`\`\`

## Safety

\`\`\`text
level: elevated
never_modify: []
require_review: [".agents/prompts/build.txt", "AGENTS.md"]   # root AGENTS.md
\`\`\`

## Metric

\`\`\`text
command: autoagent-metric-helper.sh score
name: composite_score
direction: higher
baseline: null
goal: null
weights: "0.6,0.3,0.1"
\`\`\`

## Constraints

\`\`\`text
- Tests must pass: autoagent-metric-helper.sh comprehension | awk '{exit ($1 < 0.8)}'
- Lint clean: autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'
- ShellCheck: find .agents/scripts -name '*.sh' -exec shellcheck {} \;
- Markdownlint: markdownlint-cli2 ".agents/**/*.md"
\`\`\`

## Models

\`\`\`text
researcher: sonnet
\`\`\`

## Budget

\`\`\`text
timeout: 14400
max_iterations: 50
per_experiment: 600
trials: 3
\`\`\`

## Hints

- Start with self-healing (highest signal, lowest risk)
- Progress to instruction refinement after self-healing exhausts low-hanging fruit
- Tool creation and agent composition only after iteration 20
- Equal-or-better with less code is always a win
- Elevated safety: root AGENTS.md and build.txt changes go to require_review — do not auto-keep
- 3 trials required for consistency — a change must improve in 2 of 3 runs to be kept
- pulse_outcomes requires pulse history in ~/.aidevops/.agent-workspace/; skip if absent
```
