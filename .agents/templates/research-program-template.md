---
name: {program-name}
mode: in-repo          # in-repo | cross-repo | standalone
target_repo: .         # path or "." for current repo
---

# Research: {Title}

<!-- AI-CONTEXT-START -->

A research program defines what an autoresearch session optimizes, how it measures success,
what constraints must hold, and when to stop. The subagent reads this file at session start
and uses it as the contract for the entire experiment loop.

Fields marked `# required` must be present. Fields marked `# optional` may be omitted.

<!-- AI-CONTEXT-END -->

## Target

```text
files: {glob patterns of modifiable files, comma-separated}   # required
branch: experiment/{program-name}                              # auto-generated if omitted
```

Examples:
- `files: .agents/prompts/build.txt` — single file
- `files: .agents/**/*.md` — all agent docs
- `files: src/**/*.ts, webpack.config.js` — multiple patterns

## Metric

```text
command: {shell command that outputs a single numeric value}   # required
name: {metric_name_snake_case}                                 # required
direction: lower                                               # required: lower | higher
baseline: null                                                 # auto-populated on first run
goal: null                                                     # optional: stop when reached (e.g., "< 3.0")
```

The metric command must:
- Exit 0 on success
- Print exactly one number to stdout (the subagent parses the last line)
- Be deterministic enough to distinguish signal from noise

Examples:
- Build time: `npm run build 2>&1 | grep 'Time:' | awk '{print $2}'`
- Token count: `agent-test-helper.sh run --suite .agents/tests/build-plus.json --metric tokens | tail -1`
- Test pass rate: `pytest --tb=no -q 2>&1 | grep passed | awk '{print $1}'`
- File size: `wc -c < dist/bundle.js`

## Constraints

Each constraint is a shell command that must exit 0 before the metric is measured.
The subagent runs all constraints after each modification. Failure = discard the experiment.

```text
- {constraint description}: {shell command}
```

Examples:
- Tests must pass: `npm test`
- No new dependencies: `git diff HEAD -- package.json | grep -c '^+' | awk '{exit ($1 > 0)}'`
- Lint clean: `markdownlint-cli2 .agents/**/*.md`
- ShellCheck clean: `find .agents/scripts -name '*.sh' -exec shellcheck {} \;`
- Public API unchanged: `git diff HEAD -- src/index.ts | grep -c '^[+-]export' | awk '{exit ($1 > 0)}'`

## Models

```text
researcher: sonnet     # required: model that runs the experiment loop
evaluator: haiku       # optional: model that scores qualitative output
target: sonnet         # optional: model under test (agent optimization mode only)
```

Model tiers: `haiku` (fast/cheap), `sonnet` (balanced), `opus` (best quality).

## Budget

```text
timeout: 7200          # required: total wall-clock seconds (default: 2h)
max_iterations: 50     # required: max experiment count
per_experiment: 300    # optional: max seconds per single experiment (default: 5min)
trials: 1              # optional: evaluations per hypothesis (default: 1, use 2-3 for noisy metrics)
```

Multi-trial evaluation reduces noise from stochastic metrics (e.g., LLM-scored tests). Each trial re-runs the full metric command. The median result is used for keep/discard. Set to 2-3 for LLM-based metrics, 1 for deterministic metrics (build time, file size).

## Hints

Optional human guidance for the researcher model's hypothesis generation.
The subagent reads these before generating each hypothesis.

- {hint about where to look for improvements}
- {hint about what approaches to avoid}
- {hint about known constraints or gotchas}

---

## Examples

The following are complete, runnable research programs. Copy and adapt.

---

### Example 1: Agent Instruction Optimization

```markdown
---
name: optimize-build-plus-tokens
mode: in-repo
target_repo: .
---

# Research: Reduce build-plus token usage without quality loss

## Target

\`\`\`
files: .agents/build-plus.md, .agents/prompts/build.txt
branch: experiment/optimize-build-plus-tokens
\`\`\`

## Metric

\`\`\`
command: agent-test-helper.sh run --suite .agents/tests/build-plus.json --metric tokens | tail -1
name: avg_tokens_per_task
direction: lower
baseline: null
goal: null
\`\`\`

## Constraints

- Tests must pass: `agent-test-helper.sh run --suite .agents/tests/build-plus.json --metric pass_rate | tail -1 | awk '{exit ($1 < 0.9)}'`
- Lint clean: `markdownlint-cli2 .agents/build-plus.md .agents/prompts/build.txt`

## Models

\`\`\`
researcher: sonnet
evaluator: haiku
target: sonnet
\`\`\`

## Budget

\`\`\`
timeout: 14400
max_iterations: 100
per_experiment: 600
\`\`\`

## Hints

- Redundant instructions are the primary token waste — look for rules stated twice
- Examples with long code blocks inflate tokens; prefer references to file:line
- Section headers add tokens; merge thin sections
- Avoid removing security rules or traceability requirements
```

---

### Example 2: Build Performance Optimization

```markdown
---
name: optimize-build-time
mode: in-repo
target_repo: .
---

# Research: Reduce TypeScript build time

## Target

\`\`\`
files: src/**/*.ts, tsconfig.json, webpack.config.js
branch: experiment/optimize-build-time
\`\`\`

## Metric

\`\`\`
command: npm run build 2>&1 | grep 'Time:' | awk '{print $2}'
name: build_time_seconds
direction: lower
baseline: null
goal: "< 10.0"
\`\`\`

## Constraints

- Tests must pass: `npm test`
- No new dependencies: `git diff HEAD -- package.json | grep -c '^+' | awk '{exit ($1 > 2)}'`
- Bundle size within 10%: `node -e "const s=require('fs').statSync('dist/bundle.js').size; process.exit(s > 1.1 * 512000 ? 1 : 0)"`

## Models

\`\`\`
researcher: sonnet
\`\`\`

## Budget

\`\`\`
timeout: 7200
max_iterations: 50
per_experiment: 300
\`\`\`

## Hints

- Tree-shaking opportunities in utils/ — barrel exports may prevent dead-code elimination
- tsconfig `incremental` and `composite` flags can reduce rebuild time
- Check for unnecessary `include` globs pulling in test files
- `isolatedModules: true` enables faster single-file transpilation
```

---

### Example 3: Standalone ML Experiment (cross-repo)

```markdown
---
name: prompt-compression-study
mode: standalone
target_repo: ~/Git/autoresearch-prompt-compression
---

# Research: Prompt compression techniques for code generation

## Target

\`\`\`
files: programs/compress.py, prompts/*.txt
branch: experiment/prompt-compression
\`\`\`

## Metric

\`\`\`
command: python programs/compress.py --eval | grep 'score:' | awk '{print $2}'
name: compression_score
direction: higher
baseline: null
goal: "> 0.85"
\`\`\`

## Constraints

- Eval suite passes: `python programs/compress.py --eval --strict`
- No hallucinations: `python programs/compress.py --eval | grep 'hallucinations: 0'`

## Models

\`\`\`
researcher: opus
evaluator: sonnet
\`\`\`

## Budget

\`\`\`
timeout: 28800
max_iterations: 200
per_experiment: 900
\`\`\`

## Hints

- Semantic compression (remove redundancy) outperforms syntactic compression (abbreviations)
- Code examples are high-value; compress prose around them, not the examples themselves
- Chain-of-thought prompts compress poorly — test with and without CoT
```
