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

Bridge the gap between "I have an idea" and "tasks are dispatched and executing". A mission takes a high-level goal ("Build a CRM", "Migrate to TypeScript", "Research and prototype a recommendation engine"), runs a structured scoping interview, decomposes it into milestones and features, creates a mission state file, and optionally sets up a new repo. The pulse supervisor then dispatches features as workers.

Reuses `/define` probe techniques but operates at project scope, not task scope.

## Workflow

### Step 0: Parse Arguments and Detect Mode

```bash
# Check for headless mode
HEADLESS=false
MISSION_DESC=""

if echo "$ARGUMENTS" | grep -q -- '--headless'; then
  HEADLESS=true
  MISSION_DESC=$(echo "$ARGUMENTS" | sed 's/--headless//' | xargs)
elif echo "$ARGUMENTS" | grep -q ' -- '; then
  # Supervisor dispatch format: /mission "Build a CRM" -- headless context
  HEADLESS=true
  MISSION_DESC=$(echo "$ARGUMENTS" | sed 's/ -- .*//' | xargs)
else
  MISSION_DESC=$(echo "$ARGUMENTS" | xargs)
fi
```

If `$MISSION_DESC` is empty and not headless, ask:

```text
What's the mission? Describe the end goal in one sentence.

Example: "Build a customer portal with auth, billing, and support tickets"
```

### Step 1: Mission Classification

Classify the mission to select appropriate interview probes and decomposition strategy.

| Type | Signal Words | Default Assumptions |
|------|-------------|---------------------|
| **greenfield** | build, create, launch, new, start | New repo, full stack, needs infrastructure |
| **migration** | migrate, port, convert, upgrade, move | Existing codebase, incremental, needs rollback plan |
| **research** | research, evaluate, compare, spike, prototype | Time-boxed, deliverable is recommendation + POC |
| **enhancement** | add, extend, improve, integrate, scale | Existing repo, feature branches, existing CI |
| **infrastructure** | deploy, configure, setup, provision, automate | DevOps focus, needs credentials, cloud accounts |

If ambiguous, ask:

```text
What type of mission is this?

1. Greenfield — building something new from scratch (recommended based on your description)
2. Migration — moving/converting an existing system
3. Research — investigating options with a prototype deliverable
4. Enhancement — extending an existing project
5. Infrastructure — deployment, provisioning, automation
```

Store the classification for probe selection.

### Step 2: Mode Selection

```text
How should this mission execute?

1. POC mode — fast iteration, skip ceremony (no briefs, no PRs, commit to main/branch) (recommended for research/prototypes)
2. Full mode — production-quality with worktree/PR/review workflows (recommended for greenfield/enhancement)
```

**POC mode** characteristics:
- Commits directly to main (dedicated repo) or a single long-lived branch (existing repo)
- No task briefs, no PR reviews, no preflight/postflight
- Single worker per milestone (no parallel dispatch)
- Goal: working prototype as fast as possible

**Full mode** characteristics:
- Standard worktree + PR workflow per feature
- Task briefs for each feature (auto-generated from milestone decomposition)
- Parallel worker dispatch within milestones
- Preflight quality checks, PR reviews, postflight verification

### Step 3: Budget and Constraints Interview

Ask sequentially. Each question offers concrete options with one recommended.

**Q1: Time budget**

```text
How much calendar time for this mission?

1. 1 day (8h) — tight POC, single milestone (recommended for research)
2. 2-3 days (16-24h) — focused build, 2-3 milestones
3. 1 week (40h) — full feature set, 3-5 milestones (recommended for greenfield)
4. 2+ weeks (80h+) — large project, 5+ milestones
5. No time constraint — budget-limited only
```

**Q2: Token/cost budget**

```text
What's the token/cost budget for AI compute?

1. Minimal ($5-20) — use haiku/sonnet, limit iterations (recommended for POC)
2. Moderate ($20-100) — sonnet primary, opus for decomposition only
3. Generous ($100-500) — opus for complex reasoning, sonnet for implementation (recommended for production)
4. Uncapped — use best model for each task, optimise for quality
5. Let me specify: $___
```

**Q3: Infrastructure constraints**

```text
What infrastructure is available?

1. Local only — no cloud, no deployments (recommended for POC/research)
2. Existing infrastructure — deploy to current hosting (specify provider)
3. New infrastructure needed — will provision as part of mission
4. Let me specify constraints
```

**Q4: External dependencies**

```text
Does this mission need external accounts, APIs, or services?

1. None — self-contained (recommended for POC)
2. Yes — I'll provide credentials as needed
3. Yes — the mission agent should research and recommend services
4. Let me list them
```

### Step 4: Scope Probing (Latent Requirements)

Run exactly **3 probes** adapted from `/define` techniques, selected by mission type:

**For greenfield missions:**

1. **Pre-mortem**: "Imagine this mission ships in {time_budget} and fails. What's the most likely cause?"
   - Options: scope creep, wrong tech stack, missing auth/security, performance at scale, integration failures

2. **User journey**: "Who is the primary user, and what's their first interaction with this system?"
   - Options: admin dashboard, end-user signup, API consumer, internal tool user

3. **Non-negotiables**: "What's the one thing that MUST work perfectly, even if everything else is rough?"
   - Options: auth/security, core business logic, data integrity, user onboarding, API reliability

**For migration missions:**

1. **Rollback**: "If the migration breaks production, what's the rollback plan?"
   - Options: feature flags, blue-green deploy, database rollback, keep old system running in parallel

2. **Data integrity**: "What data must survive the migration with zero loss?"
   - Options: all user data, configuration, transaction history, let me specify

3. **Incremental vs big-bang**: "Should this migrate incrementally or all at once?"
   - Options: incremental (recommended), big-bang with rollback, strangler fig pattern

**For research missions:**

1. **Decision criteria**: "What would make you choose option A over option B?"
   - Options: cost, performance, developer experience, ecosystem/community, long-term maintainability

2. **Deliverable format**: "What does the research output look like?"
   - Options: comparison doc + recommendation, working POC, architecture decision record (ADR), presentation

3. **Time-box**: "When should research stop and a decision be made, even with incomplete information?"
   - Options: after {time_budget/2}, after evaluating top 3 options, when one option clearly wins

**For enhancement/infrastructure missions:**
Select 3 probes from the greenfield and migration sets based on relevance.

### Step 5: Milestone Decomposition

This is the core intellectual work of the command. Use opus-tier reasoning to decompose the mission into sequential milestones with parallel features within each.

**Decomposition rules:**
- Milestones are sequential — each builds on the previous
- Features within a milestone are parallelisable where possible
- Each milestone has a validation criterion (how to know it's done)
- First milestone is always the smallest viable increment
- Last milestone is always "polish, docs, and deploy"
- Each feature maps to a single `/full-loop` dispatch

**Present the decomposition:**

```text
Mission: "{mission_desc}"
Mode: {poc|full}
Budget: {time_budget} / {cost_budget}
Type: {classification}

## Milestone 1: {name} (~{estimate})
Validation: {how to verify this milestone is complete}

  1. {feature_1} ~{estimate} [parallel-group:a]
  2. {feature_2} ~{estimate} [parallel-group:a]
  3. {feature_3} ~{estimate} [parallel-group:b, depends:1]

## Milestone 2: {name} (~{estimate})
Validation: {criterion}
Depends: Milestone 1

  4. {feature_4} ~{estimate}
  5. {feature_5} ~{estimate}

## Milestone N: Polish, Docs & Deploy (~{estimate})
Validation: {criterion}

  N. Documentation and README
  N+1. Deployment configuration
  N+2. End-to-end smoke test

---

Total: {n_milestones} milestones, {n_features} features
Estimated: ~{total_hours}h over {calendar_time}
Model budget: ~{token_estimate} ({cost_estimate})

Does this decomposition look right?

1. Approve and create mission (recommended)
2. Adjust milestones (add/remove/reorder)
3. Adjust features within a milestone
4. Change mode (currently: {mode})
5. Start over with different scope
```

**Budget feasibility analysis:**

Before presenting, internally verify:
- Total feature estimates fit within time budget (with 20% buffer)
- Model costs fit within token budget
- If budget is insufficient, present tiered outcomes:

```text
Budget analysis:

For {cost_budget} and {time_budget}:
- Tier 1 (guaranteed): Milestones 1-2 — {description of minimal viable outcome}
- Tier 2 (likely): Milestones 1-3 — {description of good outcome}
- Tier 3 (stretch): All milestones — {description of full outcome}

Recommendation: commit to Tier {N}, with Tier {N+1} as stretch goal.
```

### Step 6: Mission File Creation

**Determine mission location:**

```bash
# Check if we're in a git repo
if git rev-parse --show-toplevel 2>/dev/null; then
  # Repo-attached mission
  MISSION_HOME="$(git rev-parse --show-toplevel)/todo/missions"
else
  # Homeless mission (no repo yet)
  MISSION_HOME="$HOME/.aidevops/missions"
fi

# Generate mission ID (ISO date + short hash)
MISSION_ID="m-$(date +%Y%m%d)-$(echo "$MISSION_DESC" | md5sum | cut -c1-6)"
MISSION_DIR="$MISSION_HOME/$MISSION_ID"
```

**Create mission directory structure:**

```bash
mkdir -p "$MISSION_DIR"/{research,agents,scripts,assets}
```

**Write mission state file** (`mission.md`):

```markdown
---
mode: subagent
---
# Mission: {mission_desc}

## State

- **ID:** {mission_id}
- **Status:** planning
- **Mode:** {poc|full}
- **Type:** {classification}
- **Created:** {ISO date}
- **Budget:** {time_budget} / {cost_budget}
- **Model tier:** {model_routing_strategy}

## Goal

{One-paragraph description of the end state — what exists when this mission is complete}

## Constraints

- **Time:** {time_budget}
- **Cost:** {cost_budget}
- **Infrastructure:** {infrastructure_constraints}
- **External deps:** {external_dependencies}
- **Non-negotiable:** {from probe — the one thing that must work}
- **Failure mode:** {from pre-mortem probe}

## Milestones

### M1: {name}
- **Status:** pending
- **Estimate:** ~{hours}h
- **Validation:** {criterion}
- **Features:**
  - [ ] F1: {feature_1} ~{est} [parallel-group:a]
  - [ ] F2: {feature_2} ~{est} [parallel-group:a]
  - [ ] F3: {feature_3} ~{est} [depends:F1]

### M2: {name}
- **Status:** pending
- **Estimate:** ~{hours}h
- **Validation:** {criterion}
- **Depends:** M1
- **Features:**
  - [ ] F4: {feature_4} ~{est}
  - [ ] F5: {feature_5} ~{est}

{... additional milestones ...}

## Budget Tracking

| Resource | Budget | Spent | Remaining |
|----------|--------|-------|-----------|
| Time | {hours}h | 0h | {hours}h |
| Cost | ${amount} | $0 | ${amount} |
| Tokens | ~{estimate} | 0 | ~{estimate} |

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| {today} | Mission created | {1-line summary of scoping interview results} |

## Research

{Links to research/ directory contents as they're created}

## Notes

{Free-form notes, observations, blockers discovered during execution}
```

### Step 7: Optional Repo Creation

If the mission is homeless (no git repo) and the classification is `greenfield`:

```text
This mission needs a repository. Options:

1. Create new repo and initialise (recommended)
   - git init + aidevops init + README + .gitignore
   - Mission moves to todo/missions/ in the new repo
2. Use an existing repo (specify path)
3. Keep homeless for now (mission stays in ~/.aidevops/missions/)
```

If option 1:

```bash
# Ask for repo name
REPO_NAME="{sanitized mission desc or user input}"
REPO_DIR="$HOME/Git/$REPO_NAME"

mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init

# Move mission from homeless to repo-attached
mv "$MISSION_DIR" "$REPO_DIR/todo/missions/$MISSION_ID"
MISSION_DIR="$REPO_DIR/todo/missions/$MISSION_ID"

# Initialise aidevops in the new repo
# (This creates TODO.md, todo/, .agents/ symlink, etc.)
```

If option 2, move the mission directory into the specified repo's `todo/missions/`.

### Step 8: Feature-to-Task Mapping (Full Mode Only)

In Full mode, create TODO.md entries and task briefs for each feature:

```bash
for feature in features; do
  # Claim task ID
  output=$(~/.aidevops/agents/scripts/claim-task-id.sh \
    --title "$feature_title" \
    --repo-path "$(git rev-parse --show-toplevel)")

  task_id=$(echo "$output" | grep '^TASK_ID=' | cut -d= -f2)

  # Create brief from mission context
  # Brief inherits mission constraints, links to mission state file
  # Brief's "Parent task" references the mission ID

  # Add to TODO.md
  # Format: - [ ] {task_id} {feature_title} #mission:{mission_id} ~{est} ref:{ref}
done
```

In POC mode, skip task creation. The mission orchestrator dispatches features directly from the mission state file without TODO.md entries.

### Step 9: Launch Confirmation

```text
Mission created: {mission_id}

Location: {mission_dir}/mission.md
Mode: {poc|full}
Milestones: {n}
Features: {n}
{Full mode: Tasks created: t{first}-t{last}}

Next steps:

1. Start mission now — dispatch first milestone's features (recommended)
2. Review mission file first
3. Queue for next pulse cycle (supervisor will pick it up)
4. Edit mission before starting
```

If option 1, dispatch the first milestone's features:

- **POC mode**: Start a single `/full-loop` for the first feature, sequentially
- **Full mode**: Dispatch parallel features via the pulse supervisor pattern

## Headless Mode

When `--headless` is passed or `$ARGUMENTS` contains ` -- ` (supervisor dispatch):

```text
/mission --headless "Build a customer portal with auth, billing, and support tickets"
/mission "Build a CRM" -- dispatched by supervisor with context
```

In headless mode:

1. Auto-classify mission type from description
2. Default to Full mode (unless description contains "poc", "prototype", "spike", "research")
3. Apply default budget assumptions:
   - Time: 1 week (40h)
   - Cost: Moderate ($20-100)
   - Infrastructure: existing (if in a repo) or local-only (if homeless)
   - External deps: none
4. Skip all interview questions — use defaults and infer from description
5. Run milestone decomposition with opus-tier reasoning
6. Create mission state file immediately
7. Create TODO.md entries (Full mode) or mission file only (POC mode)
8. Output machine-readable summary:

```text
MISSION_ID={id}
MISSION_DIR={path}
MISSION_MODE={poc|full}
MISSION_MILESTONES={n}
MISSION_FEATURES={n}
MISSION_STATUS=planning
```

## Model Routing

The `/mission` command itself should run on **opus** for the decomposition step (Step 5). The scoping interview (Steps 1-4) can run on sonnet. Feature dispatch uses the mission's configured model tier.

Recommended routing:
- Interview + classification: sonnet (fast, cheap)
- Milestone decomposition: opus (complex reasoning, architecture decisions)
- Feature brief generation: sonnet (templated output)
- Feature implementation: per mission budget (haiku for POC, sonnet/opus for Full)

## Mission Lifecycle States

```text
planning → active → paused → completed
                  → blocked → active (when unblocked)
                  → cancelled
```

| State | Meaning | Set by |
|-------|---------|--------|
| `planning` | Mission created, not yet started | `/mission` (this command) |
| `active` | Features being dispatched and executed | Mission orchestrator |
| `paused` | Manually paused (budget, priority, blocker) | User or supervisor |
| `blocked` | Waiting on external dependency | Worker or supervisor |
| `completed` | All milestones validated | Mission orchestrator |
| `cancelled` | Abandoned | User |

## Self-Organisation

The mission agent creates files and folders as needs are discovered:

- `research/` — comparison docs, API evaluations, architecture notes
- `agents/` — mission-specific temporary agents (draft tier)
- `scripts/` — mission-specific automation scripts
- `assets/` — screenshots, PDFs, visual research

These are temporary. If a mission agent or script proves generally useful, it should be promoted to `~/.aidevops/agents/draft/` (user's draft tier) with a note in the mission's decisions log.

## Examples

```text
User: /mission Build a SaaS customer portal with auth, billing, and support tickets

AI: Classifying: **greenfield** (building something new)

Mode selection:
1. POC mode — fast prototype, skip ceremony
2. Full mode — production-quality with PR workflow (recommended)

User: 2

AI: Q1: Time budget?
1. 1 day  2. 2-3 days  3. 1 week (recommended)  4. 2+ weeks  5. No constraint

User: 3

AI: Q2: Token/cost budget?
1. Minimal ($5-20)  2. Moderate ($20-100)  3. Generous ($100-500) (recommended)  4. Uncapped  5. Specify

User: 3

AI: Q3: Infrastructure?
1. Local only  2. Existing infra  3. New infra needed (recommended)  4. Specify

User: 3

AI: Q4: External dependencies?
1. None  2. I'll provide creds  3. Agent should research (recommended)  4. List them

User: 3

AI: [Pre-mortem] Imagine this ships in 1 week and fails. Most likely cause?
1. Scope creep — too many features for 1 week (recommended)
2. Wrong tech stack choice
3. Auth/security gaps
4. Billing integration complexity

User: 1

AI: [User journey] Who's the primary user and their first interaction?
1. End-user signup and onboarding (recommended)
2. Admin dashboard
3. API consumer

User: 1

AI: [Non-negotiable] What MUST work perfectly?
1. Auth and security (recommended)
2. Billing accuracy
3. Support ticket workflow
4. User onboarding

User: 1

AI: Mission: "SaaS Customer Portal"
Mode: Full | Budget: 40h / $300 | Type: greenfield

## Milestone 1: Foundation (~8h)
Validation: User can sign up, log in, see empty dashboard

  1. Project scaffolding (Next.js + DB) ~2h [parallel-group:a]
  2. Auth system (Better Auth) ~3h [parallel-group:a]
  3. Dashboard layout + navigation ~3h [depends:1]

## Milestone 2: Billing (~10h)
Validation: User can subscribe, see invoices
Depends: Milestone 1

  4. Stripe integration ~4h
  5. Subscription management UI ~3h [depends:4]
  6. Invoice history ~3h [depends:4]

## Milestone 3: Support (~8h)
Validation: User can create ticket, admin can respond
Depends: Milestone 1

  7. Ticket data model + API ~3h
  8. Ticket creation UI ~2h [depends:7]
  9. Admin ticket management ~3h [depends:7]

## Milestone 4: Polish, Docs & Deploy (~6h)
Validation: Deployed, documented, smoke-tested

  10. End-to-end smoke tests ~2h
  11. Documentation + README ~2h
  12. Deployment config + CI ~2h

---
Total: 4 milestones, 12 features
Estimated: ~32h over 5 days (8h buffer)
Model budget: ~$180 (opus decomposition + sonnet implementation)

Budget analysis:
- Tier 1 (guaranteed): M1-M2 — auth + billing portal
- Tier 2 (likely): M1-M3 — full portal without polish
- Tier 3 (stretch): All milestones — production-ready

Approve?
1. Approve and create mission (recommended)
2. Adjust milestones
3. Adjust features
4. Change mode
5. Start over

User: 1

AI: Mission created: m-20260227-a3f2c1

Location: ~/Git/customer-portal/todo/missions/m-20260227-a3f2c1/mission.md
Mode: Full
Milestones: 4
Features: 12
Tasks created: t001-t012

Next steps:
1. Start mission now (recommended)
2. Review mission file
3. Queue for pulse
4. Edit first
```

## Related

- `scripts/commands/define.md` — Interview technique (reused for scoping)
- `scripts/commands/full-loop.md` — Worker execution (dispatched per feature)
- `scripts/commands/pulse.md` — Supervisor dispatch (mission-aware)
- `workflows/plans.md` — Planning patterns for decomposition
- `templates/brief-template.md` — Brief format (Full mode features)
- `templates/mission-template.md` — Mission state file template (t1357.1)
- `tools/build-agent/build-agent.md` — Agent lifecycle (draft tier for mission agents)
- `reference/orchestration.md` — Model routing for mission workers
