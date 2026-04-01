---
description: Autonomous experiment loop — optimize code, agents, or standalone research programs
agent: autoresearch
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: true
  bash: true
---

Run an autonomous experiment loop that modifies code, measures a metric, and keeps only improvements.

Arguments: $ARGUMENTS

---

## Invocation Patterns

| Pattern | Example | Behaviour |
|---------|---------|-----------|
| **Full program** | `/autoresearch --program todo/research/optimize-build.md` | Skip interview, run directly |
| **One-liner** | `/autoresearch "reduce build time"` | Infer defaults, short confirmation |
| **Bare** | `/autoresearch` | Full interactive setup interview |
| **Init** | `/autoresearch init "name"` | Scaffold new standalone research repo |

---

## Step 1: Resolve Invocation Pattern

```text
if $ARGUMENTS starts with "init ":
    → go to Init Mode
elif $ARGUMENTS contains "--program ":
    → extract program path, skip to Step 3
elif $ARGUMENTS is non-empty (one-liner):
    → go to One-Liner Mode
else:
    → go to Interactive Setup
```

---

## Step 2a: Interactive Setup (bare invocation)

Ask questions sequentially. Each question shows the inferred default as option 1. Accept Enter to use default.

### Q1 — What are you researching?

Suggest based on repo context:

| Signal | Suggestion |
|--------|-----------|
| Repo is aidevops | "agent instruction optimization (reduce tokens, improve pass rate)" |
| `package.json` exists | "build time reduction" or "test suite speed" |
| `pyproject.toml` / `setup.py` | "pytest suite speed" or "import time" |
| `Cargo.toml` | "cargo build time" or "benchmark regression" |
| `Makefile` / `CMakeLists.txt` | "build time" |
| No signal | "code quality improvement" |

### Q2 — Where does the work happen?

```text
1. This repo (.)                    [default]
2. Another managed repo (which?)
3. New standalone repo
```

If option 2: ask for repo path or name. Validate it exists in `~/.config/aidevops/repos.json`.
If option 3: go to Init Mode after interview.

### Q3 — What files can be modified?

Suggest based on Q1 answer:

| Q1 answer contains | Suggestion |
|--------------------|-----------|
| "agent" / "instruction" / "prompt" | `.agents/**/*.md, .agents/prompts/*.txt` |
| "build" / "webpack" / "bundle" | `webpack.config.js, tsconfig.json, src/**/*.ts` |
| "test" / "pytest" / "jest" | `tests/**/*.py, conftest.py` or `tests/**/*.ts, jest.config.js` |
| "performance" / "speed" | `src/**/*.{ts,js,py}` |
| default | `src/**/*` |

### Q4 — What's the success metric?

Suggest based on repo type and Q1:

| Context | Metric command | Name | Direction |
|---------|---------------|------|-----------|
| aidevops + "agent" | `agent-test-helper.sh run --json \| jq '.pass_rate - 0.3 * .token_ratio'` | `composite_score` | higher |
| aidevops + "token" | `agent-test-helper.sh run --json \| jq '.avg_tokens'` | `avg_tokens` | lower |
| Node + "build" | `npm run build 2>&1 \| grep 'Time:' \| awk '{print $2}'` | `build_time_seconds` | lower |
| Node + "test" | `npm test -- --json 2>/dev/null \| jq '.numPassedTests'` | `tests_passed` | higher |
| Python + "test" | `pytest --tb=no -q 2>&1 \| grep passed \| awk '{print $1}'` | `tests_passed` | higher |
| Python + "speed" | `hyperfine --runs 3 'python main.py' --export-json /tmp/bench.json && jq '.results[0].mean' /tmp/bench.json` | `execution_seconds` | lower |
| Cargo + "bench" | `cargo bench 2>&1 \| grep 'time:' \| awk '{print $5}'` | `bench_ns` | lower |
| default | ask user to provide command | — | — |

If no suggestion matches: ask user for the metric command, name, and direction.

### Q5 — Any constraints?

Auto-detect test command and pre-fill:

```text
Detected test command: npm test
Suggested constraints:
  1. Tests must pass: npm test                    [default: include]
  2. No new dependencies                          [default: include]
  3. Keep public API unchanged                    [default: skip]
  4. Lint clean                                   [default: skip]
  5. Custom constraint
```

### Q6 — Budget?

```text
Time limit:       [2h]
Max iterations:   [50]
Per-experiment:   [5m]
Goal (optional):  [none]
```

### Q7 — Models?

```text
Researcher model: [sonnet]
Evaluator model:  [haiku]   (optional — for LLM-as-judge metrics)
Target model:     [sonnet]  (only for agent optimization)
```

Only ask about Target model if Q1 mentions "agent" or "instruction".

---

## Step 2b: One-Liner Mode

Given a short description (e.g., "reduce build time"):

1. Detect repo type and infer all fields using the tables in Step 2a.
2. Generate a draft research program.
3. Show a compact summary:

```text
Research program: optimize-build-time
  Mode:       in-repo (.)
  Files:      webpack.config.js, tsconfig.json, src/**/*.ts
  Metric:     build_time_seconds (lower is better)
              npm run build 2>&1 | grep 'Time:' | awk '{print $2}'
  Constraints: npm test
  Budget:     2h / 50 iterations
  Models:     researcher=sonnet

[Enter] to confirm, [e] to edit, [q] to quit
```

If headless (no TTY): proceed without confirmation.

---

## Step 3: Write Research Program

After interview or one-liner confirmation, write the program to `todo/research/{name}.md`.

Use the schema from `.agents/templates/research-program-template.md`. The file must have:

- YAML frontmatter with `name`, `mode`, `target_repo`
- `## Target` section with `files:` and `branch:`
- `## Metric` section with `command:`, `name:`, `direction:`, `baseline: null`
- `## Constraints` section (may be empty)
- `## Models` section
- `## Budget` section

Confirm: "Research program written to `todo/research/{name}.md`."

---

## Step 4: Dispatch Decision

```text
Begin now or queue for later?
  1. Begin now (dispatch to autoresearch subagent)    [default]
  2. Queue for later (add to TODO.md)
  3. Show program file and exit
```

If headless: begin now (option 1).

**If begin now:** dispatch to `.agents/tools/autoresearch/autoresearch.md` with `--program todo/research/{name}.md`.

**If queue:** add to TODO.md:

```text
- [ ] t{next_id} autoresearch: {name} — {one-line description} #auto-dispatch ~{budget.timeout/3600}h ref:GH#{issue}
```

---

## Init Mode (`/autoresearch init "name"`)

Scaffold a new standalone research repo at `~/Git/autoresearch-{name}/`.

```bash
# 1. Create directory and git init
mkdir -p ~/Git/autoresearch-{name}
git -C ~/Git/autoresearch-{name} init

# 2. Run aidevops init
aidevops init --path ~/Git/autoresearch-{name} --non-interactive

# 3. Create baseline program
mkdir -p ~/Git/autoresearch-{name}/todo/research
# Write program.md from template with mode: standalone

# 4. Register in repos.json
# Add entry: { "slug": "local/autoresearch-{name}", "path": "~/Git/autoresearch-{name}", "local_only": true, "pulse": false }

# 5. Optional: create GitHub remote
# Ask: "Create GitHub remote? [y/N]"
# If yes: gh repo create autoresearch-{name} --private --source ~/Git/autoresearch-{name} --push
# Update repos.json: remove local_only, set slug to "owner/autoresearch-{name}"
```

After scaffolding: "Repo ready at `~/Git/autoresearch-{name}/`. Edit `todo/research/program.md` to define your experiment, then run `/autoresearch --program todo/research/program.md`."

---

## Context Detection Reference

| File present | Repo type | Default metric category |
|-------------|-----------|------------------------|
| `package.json` | Node.js | build time or test count |
| `pyproject.toml` / `setup.py` | Python | pytest pass rate or execution time |
| `Cargo.toml` | Rust | cargo bench or build time |
| `Makefile` | C/C++/generic | make time |
| `.agents/` directory | aidevops | agent pass rate + token count |
| `go.mod` | Go | go test or go build time |

---

## Related

`.agents/templates/research-program-template.md` · `.agents/tools/autoresearch/autoresearch.md` · `todo/research/`
