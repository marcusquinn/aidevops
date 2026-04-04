<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1743: /autoresearch Command Doc with Interactive Setup

## Origin

- **Created:** 2026-04-01
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + AI (interactive)
- **Parent task:** t1741
- **Conversation context:** Discussed that when users don't provide all values, the command should ask for them with context-aware suggestions and sensible defaults.

## What

Create `.agents/scripts/commands/autoresearch.md` — the slash command doc that handles three invocation patterns:

1. **Full program file:** `/autoresearch --program todo/research/optimize-build.md` — skip interview, run directly
2. **One-liner with inference:** `/autoresearch "reduce build time"` — infer defaults from context, short confirmation
3. **Bare invocation:** `/autoresearch` — full interactive setup interview
4. **Standalone init:** `/autoresearch init "name"` — scaffold new research repo

## Why

The command doc is the user-facing entry point. Without it, users can't invoke autoresearch. The interactive setup is critical because research programs have ~10 fields that are tedious to specify manually — the command should infer as many as possible and only ask for what it can't determine.

## How (Approach)

Follow existing command doc patterns (`.agents/scripts/commands/full-loop.md`, `/define`).

### Interactive setup interview

When invoked without a complete program file:

```
1. What are you researching?
   → Suggest based on repo context (e.g., "agent instruction optimization" in aidevops)

2. Where does the work happen?
   → This repo / Another repo (which?) / New standalone repo
   → Default: this repo

3. What files can be modified?
   → Suggest based on answer to #1 (e.g., ".agents/**/*.md" for agent optimization)

4. What's the success metric?
   → Metric command, name, direction
   → Suggest based on repo type:
     - aidevops: "agent-test-helper.sh run → pass rate + token count"
     - Node project: "npm run build → build time" or "npm test -- --coverage → coverage %"
     - Python project: "pytest → pass rate" or "hyperfine 'python main.py' → execution time"

5. Any constraints?
   → Default: "tests must pass" (auto-detect test command)
   → Suggest: "no new dependencies", "keep public API"

6. Budget?
   → Time: [2h] / Iterations: [50] / Goal: [none]
   → Default: 2h, 50 iterations

7. Models?
   → Researcher: [sonnet] / Evaluator: [haiku] / Target: [sonnet]
   → Only ask about Target if agent optimization detected

8. Concurrency?
   → Sequential [default] / Population-based (N hypotheses per iteration) / Multi-dimension
   → If multi-dimension: "Which independent dimensions?" with file target split suggestion
   → Default: sequential (safest, lowest cost)
   → Suggest population-based if user mentions "fast" or "overnight"
   → Suggest multi-dimension if multiple independent metrics detected
```

### Context detection logic

| Signal | Inference |
|---|---|
| Repo is aidevops | Suggest agent optimization, list test suites |
| `package.json` exists | Suggest npm-based metrics |
| `pyproject.toml`/`setup.py` | Suggest pytest-based metrics |
| `Cargo.toml` | Suggest cargo bench/test metrics |
| `Makefile`/`CMakeLists.txt` | Suggest build time metrics |
| User says "prompt" | Suggest LLM-as-judge evaluation |
| User says "performance" | Suggest hyperfine benchmarking |

### Concurrency CLI flags

```
/autoresearch --population 4           # 4 hypotheses per iteration, keep best
/autoresearch --dimensions "build-perf,test-speed,bundle-size"  # multi-dimension
/autoresearch --concurrent 3           # shorthand: 3 sequential agents on different repos
```

For multi-dimension mode, the command must:
1. Validate file targets don't overlap between dimensions (error if they do)
2. Generate a shared convoy ID for mailbox grouping
3. Dispatch each dimension as a separate subagent session with its own worktree
4. Show a summary when all dimensions complete

### Output

After interview, the command:
1. Writes the research program to `todo/research/{name}.md`
2. Confirms with user: "Research program ready. Begin now or queue for later?"
3. If begin: dispatches to the autoresearch subagent (or multiple for multi-dimension)
4. If queue: adds to TODO.md as a pending task

Reference: `.agents/scripts/commands/full-loop.md` for command doc structure.

## Acceptance Criteria

- [ ] Command doc exists at `.agents/scripts/commands/autoresearch.md`
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/scripts/commands/autoresearch.md"
  ```
- [ ] Handles all 4 invocation patterns (full program, one-liner, bare, init)
  ```yaml
  verify:
    method: codebase
    pattern: "--program|autoresearch init|Interactive Setup"
    path: ".agents/scripts/commands/autoresearch.md"
  ```
- [ ] Interactive setup includes context-aware suggestions
  ```yaml
  verify:
    method: codebase
    pattern: "package.json|pyproject|Cargo.toml|agent-test"
    path: ".agents/scripts/commands/autoresearch.md"
  ```
- [ ] Every interview question has a default value
- [ ] Concurrency question (#8) offers sequential/population/multi-dimension with context-aware suggestion
  ```yaml
  verify:
    method: codebase
    pattern: "population|dimension|concurrent|sequential"
    path: ".agents/scripts/commands/autoresearch.md"
  ```
- [ ] Multi-dimension mode validates non-overlapping file targets
- [ ] Output writes a valid research program file per t1742 schema
- [ ] YAML frontmatter in command doc follows conventions (description, agent, mode, model)
- [ ] Lint clean (markdownlint)

## Context & Decisions

- Interactive interview over CLI flags: most users won't know all the fields upfront. Interview with defaults is faster than reading docs and composing a YAML file.
- Context detection is best-effort: if detection fails, fall back to asking the user. Don't block on imperfect inference.
- One-liner mode exists because experienced users shouldn't be forced through 7 questions when they can express intent in a phrase.

## Relevant Files

- `.agents/scripts/commands/full-loop.md` — command doc pattern to follow
- `.agents/scripts/commands/define.md` — interactive interview pattern (if exists)
- `.agents/templates/research-program-template.md` — output format (t1742)
- `.agents/scripts/mail-helper.sh` — mailbox system for multi-dimension convoy grouping

## Dependencies

- **Blocked by:** t1742 (needs the schema to generate valid programs)
- **Blocks:** t1744 (subagent reads what this command produces)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review full-loop.md, define.md patterns |
| Context detection logic | 1h | Repo type detection, metric suggestions |
| Interview flow | 1h | Questions, defaults, validation |
| Init mode | 30m | Standalone repo scaffolding invocation |
| Concurrency interview + validation | 1h | Question #8, file overlap check, convoy ID |
| **Total** | **~4h** | |
