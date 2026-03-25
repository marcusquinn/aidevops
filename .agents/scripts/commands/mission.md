---
description: Interactive mission scoping — decompose a high-level goal into milestones, features, and a mission state file for autonomous multi-day execution
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  task: true
  webfetch: true
---

Scope, plan, and launch a mission — an autonomous multi-day project that goes from idea to delivery.

Topic: $ARGUMENTS

## Purpose

Bridge the gap between "I have an idea" and "tasks are dispatched and executing". A mission takes a high-level goal, runs a structured scoping interview, decomposes it into milestones and features, creates a mission state file, and optionally sets up a new repo. The pulse supervisor then dispatches features as workers.

Reuses `/define` probe techniques but operates at project scope, not task scope.

## Workflow

### Step 0: Parse Arguments and Detect Mode

```bash
HEADLESS=false
MISSION_DESC=""

if echo "$ARGUMENTS" | grep -q -- '--headless'; then
  HEADLESS=true
  MISSION_DESC=$(echo "$ARGUMENTS" | sed 's/--headless//' | xargs)
elif echo "$ARGUMENTS" | grep -q ' -- '; then
  HEADLESS=true
  MISSION_DESC=$(echo "$ARGUMENTS" | sed 's/ -- .*//' | xargs)
else
  MISSION_DESC=$(echo "$ARGUMENTS" | xargs)
fi
```

If `$MISSION_DESC` is empty and not headless, ask: "What's the mission? Describe the end goal in one sentence."

### Step 1: Mission Classification

| Type | Signal Words | Default Assumptions |
|------|-------------|---------------------|
| **greenfield** | build, create, launch, new, start | New repo, full stack, needs infrastructure |
| **migration** | migrate, port, convert, upgrade, move | Existing codebase, incremental, needs rollback plan |
| **research** | research, evaluate, compare, spike, prototype | Time-boxed, deliverable is recommendation + POC |
| **enhancement** | add, extend, improve, integrate, scale | Existing repo, feature branches, existing CI |
| **infrastructure** | deploy, configure, setup, provision, automate | DevOps focus, needs credentials, cloud accounts |

If ambiguous, present numbered options and ask.

### Step 2: Mode Selection

```text
1. POC mode — fast iteration, skip ceremony (no briefs, no PRs, commit to main/branch)
2. Full mode — production-quality with worktree/PR/review workflows (recommended for greenfield/enhancement)
```

**POC mode**: Commits directly to main/branch, no task briefs, no PR reviews, single worker per milestone.

**Full mode**: Standard worktree + PR workflow, task briefs per feature, parallel worker dispatch, preflight/postflight.

### Step 3: Budget and Constraints Interview

Ask sequentially with numbered options and one recommended:

**Q1: Time budget** — 1 day / 2-3 days / 1 week (recommended for greenfield) / 2+ weeks / No constraint

**Q2: Token/cost budget** — Minimal ($5-20) / Moderate ($20-100) / Generous ($100-500, recommended for production) / Uncapped / Specify

**Q3: Infrastructure** — Local only / Existing infrastructure / New infrastructure needed / Specify

**Q4: External dependencies** — None / I'll provide credentials / Agent should research / List them

### Step 4: Scope Probing (Latent Requirements)

Run exactly **3 probes** selected by mission type:

**Greenfield**: (1) Pre-mortem — "Imagine this fails in {time_budget}. Most likely cause?" (2) User journey — "Who is the primary user and their first interaction?" (3) Non-negotiables — "What MUST work perfectly?"

**Migration**: (1) Rollback plan (2) Data integrity requirements (3) Incremental vs big-bang

**Research**: (1) Decision criteria (2) Deliverable format (3) Time-box for decision

**Enhancement/Infrastructure**: Select 3 probes from greenfield and migration sets based on relevance.

### Step 5: Milestone Decomposition

**Rules**:
- Milestones are sequential — each builds on the previous
- Features within a milestone are parallelisable where possible
- Each milestone has a validation criterion
- First milestone = smallest viable increment
- Last milestone = "polish, docs, and deploy"
- Each feature maps to a single `/full-loop` dispatch

**Present the decomposition:**

```text
Mission: "{mission_desc}"
Mode: {poc|full} | Budget: {time_budget} / {cost_budget} | Type: {classification}

## Milestone 1: {name} (~{estimate})
Validation: {criterion}
  1. {feature_1} ~{est} [parallel-group:a]
  2. {feature_2} ~{est} [parallel-group:a]
  3. {feature_3} ~{est} [depends:1]

## Milestone N: Polish, Docs & Deploy (~{estimate})
  N. Documentation and README
  N+1. Deployment configuration
  N+2. End-to-end smoke test

Total: {n} milestones, {n} features | Estimated: ~{hours}h | Model budget: ~{cost}

1. Approve and create mission (recommended)
2. Adjust milestones  3. Adjust features  4. Change mode  5. Start over
```

**Budget feasibility analysis:**

```bash
~/.aidevops/agents/scripts/budget-analysis-helper.sh recommend --goal "{mission_desc}" --json
~/.aidevops/agents/scripts/budget-analysis-helper.sh analyse --budget {cost_budget} --hours {time_budget} --json
~/.aidevops/agents/scripts/budget-analysis-helper.sh forecast --days 7 --json
```

If budget is insufficient, present tiered outcomes: Tier 1 (guaranteed) / Tier 2 (likely) / Tier 3 (stretch).

### Step 6: Mission File Creation

```bash
if top_level=$(git rev-parse --show-toplevel 2>/dev/null); then
  MISSION_HOME="$top_level/todo/missions"
else
  MISSION_HOME="$HOME/.aidevops/missions"
fi

HASH=$(printf '%s' "$MISSION_DESC" | { md5 -q 2>/dev/null || md5sum | cut -d' ' -f1; } | cut -c1-6)
MISSION_ID="m-$(date +%Y%m%d)-${HASH}"
MISSION_DIR="$MISSION_HOME/$MISSION_ID"
mkdir -p "$MISSION_DIR"/{research,agents,scripts,assets}
```

**Mission state file** (`mission.md`) structure:

```markdown
---
mode: subagent
---
# Mission: {mission_desc}

## State
- **ID:** {mission_id} | **Status:** planning | **Mode:** {poc|full}
- **Type:** {classification} | **Created:** {ISO date}
- **Budget:** {time_budget} / {cost_budget} | **Model tier:** {strategy}

## Goal
{One-paragraph description of the end state}

## Constraints
- Time/Cost/Infrastructure/External deps/Non-negotiable/Failure mode

## Milestones
### M1: {name}
- **Status:** pending | **Estimate:** ~{hours}h | **Validation:** {criterion}
- **Features:**
  - [ ] F1: {feature_1} ~{est} [parallel-group:a]
  - [ ] F2: {feature_2} ~{est} [depends:F1]

## Budget Tracking
| Resource | Budget | Spent | Remaining |
|----------|--------|-------|-----------|
| Time | {hours}h | 0h | {hours}h |
| Cost | ${amount} | $0 | ${amount} |

## Decisions Log
| Date | Decision | Rationale |

## Notes
```

### Step 7: Optional Repo Creation

If homeless (no git repo) and greenfield, offer:

1. Create new repo and initialise (recommended) — `git init + aidevops init`
2. Use an existing repo (specify path)
3. Keep homeless for now

```bash
REPO_DIR="$HOME/Git/$REPO_NAME"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
mkdir -p "$REPO_DIR/todo/missions" || { echo "ERROR: Failed to create $REPO_DIR/todo/missions" >&2; exit 1; }
mv "$MISSION_DIR" "$REPO_DIR/todo/missions/$MISSION_ID" || { echo "ERROR: Failed to move mission to repo" >&2; exit 1; }
```

### Step 8: Feature-to-Task Mapping (Full Mode Only)

```bash
repo_path=$(git rev-parse --show-toplevel)

while IFS= read -r feature_title; do
  output=$(~/.aidevops/agents/scripts/claim-task-id.sh \
    --title "$feature_title" \
    --repo-path "$repo_path")
  task_id=$(echo "$output" | grep '^TASK_ID=' | cut -d= -f2)
  # Create brief from mission context; add to TODO.md
  # Format: - [ ] {task_id} {feature_title} #mission:{mission_id} ~{est} ref:{ref}
done < <(awk '/^- \[ \] F[0-9]+:/{sub(/^- \[ \] F[0-9]+: /,""); print}' "$MISSION_DIR/mission.md")
```

In POC mode, skip task creation — the mission orchestrator dispatches features directly from the mission state file.

### Step 9: Launch Confirmation

```text
Mission created: {mission_id}
Location: {mission_dir}/mission.md | Mode: {poc|full} | Milestones: {n} | Features: {n}

1. Start mission now — dispatch first milestone's features (recommended)
2. Review mission file first
3. Queue for next pulse cycle
4. Edit mission before starting
```

If option 1: POC mode starts a single `/full-loop` sequentially; Full mode dispatches parallel features via the pulse supervisor.

## Headless Mode

When `--headless` or ` -- ` in arguments:

1. Auto-classify mission type from description
2. Default to Full mode (unless description contains "poc", "prototype", "spike", "research")
3. Apply defaults: Time 1 week, Cost moderate, Infrastructure existing/local-only, External deps none
4. Skip all interview questions
5. Run milestone decomposition with opus-tier reasoning
6. Create mission state file and TODO.md entries (Full) or mission file only (POC)
7. Output machine-readable summary:

```text
MISSION_ID={id}
MISSION_DIR={path}
MISSION_MODE={poc|full}
MISSION_MILESTONES={n}
MISSION_FEATURES={n}
MISSION_STATUS=planning
```

## Model Routing

- Interview + classification: sonnet (fast, cheap)
- Milestone decomposition: **opus** (complex reasoning, architecture decisions)
- Feature brief generation: sonnet (templated output)
- Feature implementation: per mission budget (haiku for POC, sonnet/opus for Full)

## Mission Lifecycle States

```text
planning → active → paused → completed
                  → blocked → active (when unblocked)
                  → cancelled
```

## Self-Organisation

The mission agent creates files as needs are discovered:

- `research/` — comparison docs, API evaluations, architecture notes
- `agents/` — mission-specific temporary agents (draft tier)
- `scripts/` — mission-specific automation scripts
- `assets/` — screenshots, PDFs, visual research

If a mission agent or script proves generally useful, promote to `~/.aidevops/agents/draft/` and note in the decisions log.

## Related

- `scripts/commands/define.md` — Interview technique (reused for scoping)
- `scripts/commands/full-loop.md` — Worker execution (dispatched per feature)
- `scripts/commands/pulse.md` — Supervisor dispatch (mission-aware)
- `workflows/plans.md` — Planning patterns for decomposition
- `templates/brief-template.md` — Brief format (Full mode features)
- `templates/mission-template.md` — Mission state file template (t1357.1)
- `tools/build-agent/build-agent.md` — Agent lifecycle (draft tier for mission agents)
- `reference/orchestration.md` — Model routing for mission workers
- `scripts/budget-analysis-helper.sh` — Budget analysis engine (t1357.7)
- `scripts/budget-tracker-helper.sh` — Append-only cost log for historical spend data
- `scripts/commands/budget-analysis.md` — `/budget-analysis` command for interactive use
