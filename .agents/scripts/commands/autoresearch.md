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

## Invocation Patterns

| Pattern | Example | Behaviour |
|---------|---------|-----------|
| **Full program** | `/autoresearch --program todo/research/optimize-build.md` | Skip interview, run directly |
| **One-liner** | `/autoresearch "reduce build time"` | Infer defaults, short confirmation |
| **Bare** | `/autoresearch` | Full interactive setup interview |
| **Init** | `/autoresearch init "name"` | Scaffold new standalone research repo |

## Step 1: Resolve Invocation Pattern

```text
if $ARGUMENTS starts with "init ":      → Init Mode
elif $ARGUMENTS contains "--program ":  → extract program path, skip to Step 3
elif $ARGUMENTS is non-empty:           → One-Liner Mode
else:                                   → Interactive Setup
```

## Step 2a: Interactive Setup (bare invocation)

Ask questions sequentially. Each question shows the inferred default as option 1. Accept Enter to use default.

### Q1 — What are you researching?

| Signal | Suggestion |
|--------|-----------|
| Repo is aidevops | "agent instruction optimization (reduce tokens, improve pass rate)" |
| `package.json` exists | "build time reduction" or "test suite speed" |
| `pyproject.toml` / `setup.py` | "pytest suite speed" or "import time" |
| `Cargo.toml` | "cargo build time" or "benchmark regression" |
| `Makefile` / `CMakeLists.txt` | "build time" |
| `go.mod` | "go test or go build time" |
| No signal | "code quality improvement" |

### Q2 — Where does the work happen?

```text
1. This repo (.)                    [default]
2. Another managed repo (which?)
3. New standalone repo
```

Option 2: validate repo path exists in `~/.config/aidevops/repos.json`. Option 3: go to Init Mode.

### Q3 — What files can be modified?

| Q1 answer contains | Suggestion |
|--------------------|-----------|
| "agent" / "instruction" / "prompt" | `.agents/**/*.md, .agents/prompts/*.txt` |
| "build" / "webpack" / "bundle" | `webpack.config.js, tsconfig.json, src/**/*.ts` |
| "test" / "pytest" / "jest" | `tests/**/*.py, conftest.py` or `tests/**/*.ts, jest.config.js` |
| "performance" / "speed" | `src/**/*.{ts,js,py}` |
| default | `src/**/*` |

### Q4 — What's the success metric?

| Context | Metric command | Name | Direction |
|---------|---------------|------|-----------|
| aidevops + "agent" | `agent-test-helper.sh run {suite} --json \| jq '.composite_score'` | `composite_score` | higher |
| aidevops + "token" | `agent-test-helper.sh run {suite} --json \| jq '.avg_response_chars'` | `avg_response_chars` | lower |
| Node + "build" | `npm run build 2>&1 \| grep 'Time:' \| awk '{print $2}'` | `build_time_seconds` | lower |
| Node + "test" | `npm test -- --json 2>/dev/null \| jq '.numPassedTests'` | `tests_passed` | higher |
| Python + "test" | `pytest --tb=no -q 2>&1 \| grep passed \| awk '{print $1}'` | `tests_passed` | higher |
| Python + "speed" | `hyperfine --runs 3 'python main.py' --export-json /tmp/bench.json && jq '.results[0].mean' /tmp/bench.json` | `execution_seconds` | lower |
| Cargo + "bench" | `cargo bench 2>&1 \| grep 'time:' \| awk '{print $5}'` | `bench_ns` | lower |
| default | ask user to provide command | — | — |

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

## Step 2b: One-Liner Mode

Detect repo type and infer all fields using the tables in Step 2a. Show compact summary:

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

## Step 3: Write Research Program

Write to `todo/research/{name}.md` using schema from `.agents/templates/research-program-template.md`:

- YAML frontmatter: `name`, `mode`, `target_repo`
- `## Target`: `files:`, `branch:`
- `## Metric`: `command:`, `name:`, `direction:`, `baseline: null`
- `## Constraints` (may be empty)
- `## Models`
- `## Budget`

Confirm: "Research program written to `todo/research/{name}.md`."

## Step 4: Dispatch Decision

```text
Begin now or queue for later?
  1. Begin now (dispatch to autoresearch subagent)    [default]
  2. Queue for later (add to TODO.md)
  3. Show program file and exit
```

If headless: begin now (option 1).

**Begin now:** dispatch to `.agents/tools/autoresearch/autoresearch.md` with `--program todo/research/{name}.md`.

**Queue:** add to TODO.md:

```text
- [ ] t{next_id} autoresearch: {name} — {one-line description} #auto-dispatch ~{budget.timeout/3600}h ref:GH#{issue}
```

## Init Mode (`/autoresearch init "name"`)

Scaffold a new standalone research repo at `~/Git/autoresearch-{name}/`.

The `autoresearch-` prefix is mandatory — makes repos discoverable via `ls ~/Git/autoresearch-*` and `grep autoresearch ~/.config/aidevops/repos.json`.

### I1: Validate name

Slugify `{name}`: lowercase, hyphens for spaces/underscores, strip non-alphanumeric except hyphens. If `~/Git/autoresearch-{name}` already exists: exit with error.

### I2: Interactive prompts (skip if headless)

```text
1. Description? (one line, for README)  → [Enter to skip]
2. Create GitHub remote? [y/N]          → N
3. Enable pulse dispatch? [y/N]         → N
4. Begin experiment loop now? [y/N]     → N
```

Headless defaults: description=empty, GitHub remote=no, pulse=no, begin now=no.

### I3: Scaffold

```bash
mkdir -p "$REPO_PATH/baseline" "$REPO_PATH/results" "$REPO_PATH/todo/research"
touch "$REPO_PATH/baseline/.gitkeep" "$REPO_PATH/results/.gitkeep"
```

Write `$REPO_PATH/program.md` (README with structure overview) and `$REPO_PATH/todo/research/program.md` from `.agents/templates/research-program-template.md` with `name`, `mode: standalone`, `target_repo: .`, `files: baseline/**/*`.

Write `$REPO_PATH/.gitignore`:

```text
results/
*.log
.DS_Store
```

### I4: Git init

```bash
git -C "$REPO_PATH" init && git -C "$REPO_PATH" add . && git -C "$REPO_PATH" commit -m "chore: init autoresearch-{name} repo"
```

### I5: aidevops init

```bash
aidevops init --path "$REPO_PATH" --non-interactive
```

If unavailable: warn and continue.

### I6: Register in repos.json

Add to `initialized_repos` in `~/.config/aidevops/repos.json`:

```json
{
  "path": "~/Git/autoresearch-{name}",
  "slug": "local/autoresearch-{name}",
  "local_only": true,
  "pulse": false,
  "priority": "research",
  "app_type": "generic",
  "maintainer": "{gh_username}"
}
```

Get `{gh_username}` from `gh api user --jq '.login' 2>/dev/null`.

### I7: Optional GitHub remote

```bash
gh repo create "autoresearch-{name}" --private --source "$REPO_PATH" --push
```

On success: remove `local_only`, set `slug: "{gh_username}/autoresearch-{name}"`. On failure: warn, keep `local_only: true`.

### I8: Optional pulse

Set `"pulse": true` in repos.json. Suggest `"pulse_hours": {"start": 17, "end": 5}` for overnight-only runs.

### I9: Optional begin now

If yes: dispatch `/autoresearch --program "$REPO_PATH/todo/research/program.md"`.

Otherwise:

```text
Repo ready at ~/Git/autoresearch-{name}/
Next steps:
  1. Edit todo/research/program.md — define your experiment (metric, files, budget)
  2. Add starting code/data to baseline/
  3. Run: /autoresearch --program ~/Git/autoresearch-{name}/todo/research/program.md
```

## Related

`.agents/templates/research-program-template.md` · `.agents/tools/autoresearch/autoresearch.md` · `todo/research/` · `todo/research/agent-optimization.md`
