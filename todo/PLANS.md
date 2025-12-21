# Execution Plans

Complex, multi-session work requiring research, design decisions, and detailed tracking.

Based on [OpenAI's PLANS.md](https://cookbook.openai.com/articles/codex_exec_plans) and [plan.md](https://github.com/Digital-Tvilling/plan.md), with TOON-enhanced parsing.

<!--TOON:meta{version,format,updated}:
1.0,plans-md+toon,2025-12-20T00:00:00Z
-->

## Format

Each plan includes:
- **Status**: Planning / In Progress (Phase X/Y) / Blocked / Completed
- **Time Estimate**: `~2w (ai:1w test:0.5w read:0.5w)`
- **Timestamps**: `logged:`, `started:`, `completed:`
- **Progress**: Timestamped checkboxes with estimates and actuals
- **Decision Log**: Key decisions with rationale
- **Surprises & Discoveries**: Unexpected findings
- **Outcomes & Retrospective**: Results and lessons (when complete)

## Active Plans

### [2025-12-21] aidevops-opencode Plugin

**Status:** Planning
**Estimate:** ~2d (ai:1d test:0.5d read:0.5d)
**Architecture:** [.agent/build-mcp/aidevops-plugin.md](../.agent/build-mcp/aidevops-plugin.md)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p001,aidevops-opencode Plugin,planning,0,4,,opencode|plugin,2d,1d,0.5d,0.5d,2025-12-21T01:50Z,
-->

#### Purpose

Create an optional OpenCode plugin that provides native integration for aidevops. This enables lifecycle hooks (pre-commit quality checks), dynamic agent loading, and cleaner npm-based installation for OpenCode users who want tighter integration.

#### Context from Discussion

**Key decisions:**
- Plugin is **optional enhancement**, not replacement for current multi-tool approach
- aidevops remains compatible with Claude, Cursor, Windsurf, etc.
- Plugin loads agents from `~/.aidevops/agents/` at runtime
- Should detect and complement oh-my-opencode if both installed

**Architecture (from aidevops-plugin.md):**
- Agent loader from `~/.aidevops/agents/`
- MCP registration programmatically
- Pre-commit quality hooks (ShellCheck)
- aidevops CLI exposed as tool

**When to build:**
- When OpenCode becomes dominant enough
- When users request native plugin experience
- When hooks become essential (quality gates)

#### Progress

- [ ] (2025-12-21) Phase 1: Core plugin structure + agent loader ~4h
- [ ] (2025-12-21) Phase 2: MCP registration ~2h
- [ ] (2025-12-21) Phase 3: Quality hooks (pre-commit) ~3h
- [ ] (2025-12-21) Phase 4: oh-my-opencode compatibility ~2h

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m001,p001,Phase 1: Core plugin structure + agent loader,4h,,2025-12-21T00:00Z,,pending
m002,p001,Phase 2: MCP registration,2h,,2025-12-21T00:00Z,,pending
m003,p001,Phase 3: Quality hooks (pre-commit),3h,,2025-12-21T00:00Z,,pending
m004,p001,Phase 4: oh-my-opencode compatibility,2h,,2025-12-21T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Keep as optional plugin, not replace current approach
  **Rationale:** aidevops must remain multi-tool compatible (Claude, Cursor, etc.)
  **Date:** 2025-12-21

<!--TOON:decisions[1]{id,plan_id,decision,rationale,date,impact}:
d001,p001,Keep as optional plugin,aidevops must remain multi-tool compatible,2025-12-21,None - additive feature
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] Claude Code Destructive Command Hooks

**Status:** Planning
**Estimate:** ~4h (ai:2h test:1h read:1h)
**Source:** [Dicklesworthstone's guide](https://github.com/Dicklesworthstone/misc_coding_agent_tips_and_scripts/blob/main/DESTRUCTIVE_GIT_COMMAND_CLAUDE_HOOKS_SETUP.md)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p002,Claude Code Destructive Command Hooks,planning,0,4,,claude|git|security,4h,2h,1h,1h,2025-12-21T12:00Z,
-->

#### Purpose

Implement Claude Code PreToolUse hooks to mechanically block destructive git and filesystem commands. Instructions in AGENTS.md don't prevent execution - this provides enforcement at the tool level.

**Problem:** On Dec 17, 2025, an AI agent ran `git checkout --` on files with hours of uncommitted work, destroying it instantly. AGENTS.md forbade this, but instructions alone don't prevent accidents.

**Solution:** Python hook script that intercepts Bash commands before execution and blocks dangerous patterns.

#### Context from Discussion

**Commands to block:**
- `git checkout -- <files>` - discards uncommitted changes
- `git restore <files>` - same as checkout (newer syntax)
- `git reset --hard` - destroys all uncommitted changes
- `git clean -f` - removes untracked files permanently
- `git push --force` / `-f` - destroys remote history
- `git branch -D` - force-deletes without merge check
- `rm -rf` (non-temp paths) - recursive deletion
- `git stash drop/clear` - permanently deletes stashes

**Safe patterns (allowlisted):**
- `git checkout -b <branch>` - creates new branch
- `git restore --staged` - only unstages, doesn't discard
- `git clean -n` / `--dry-run` - preview only
- `rm -rf /tmp/...`, `/var/tmp/...`, `$TMPDIR/...` - temp dirs

**Key decisions:**
- Adapt for aidevops: install to `~/.aidevops/hooks/` not `.claude/hooks/`
- Support both Claude Code and OpenCode (if hooks compatible)
- Add installer to `setup.sh` for automatic deployment
- Document in `workflows/git-workflow.md`

#### Progress

- [ ] (2025-12-21) Phase 1: Create git_safety_guard.py adapted for aidevops ~1h
- [ ] (2025-12-21) Phase 2: Create installer script with global/project options ~1h
- [ ] (2025-12-21) Phase 3: Integrate into setup.sh ~30m
- [ ] (2025-12-21) Phase 4: Document in workflows and test ~1.5h

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m005,p002,Phase 1: Create git_safety_guard.py adapted for aidevops,1h,,2025-12-21T12:00Z,,pending
m006,p002,Phase 2: Create installer script with global/project options,1h,,2025-12-21T12:00Z,,pending
m007,p002,Phase 3: Integrate into setup.sh,30m,,2025-12-21T12:00Z,,pending
m008,p002,Phase 4: Document in workflows and test,1.5h,,2025-12-21T12:00Z,,pending
-->

#### Decision Log

- **Decision:** Install hooks to `~/.aidevops/hooks/` by default
  **Rationale:** Consistent with aidevops directory structure, global protection
  **Date:** 2025-12-21

- **Decision:** Keep original Python implementation (not Bash)
  **Rationale:** JSON parsing is cleaner in Python, original is well-tested
  **Date:** 2025-12-21

<!--TOON:decisions[2]{id,plan_id,decision,rationale,date,impact}:
d002,p002,Install hooks to ~/.aidevops/hooks/,Consistent with aidevops directory structure,2025-12-21,None
d003,p002,Keep original Python implementation,JSON parsing cleaner in Python - original well-tested,2025-12-21,None
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

### [2025-12-21] Evaluate Merging build-agent and build-mcp into aidevops

**Status:** Planning
**Estimate:** ~4h (ai:2h test:1h read:1h)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p003,Evaluate Merging build-agent and build-mcp into aidevops,planning,0,3,,architecture|agents,4h,2h,1h,1h,2025-12-21T14:00Z,
-->

#### Purpose

Evaluate whether `build-agent.md` and `build-mcp.md` should be merged into `aidevops.md`. When enhancing aidevops, we often build agents and MCPs - these are tightly coupled activities that may benefit from consolidation.

#### Context from Discussion

**Current structure:**
- `build-agent.md` - Agent design, ~50-100 instruction budget, subagent: `agent-review.md`
- `build-mcp.md` - MCP development (TypeScript/Bun/Elysia), subagents: server-patterns, transports, deployment, api-wrapper
- `aidevops.md` - Framework operations, already references build-agent as "Related Main Agent"
- All three are `mode: subagent` - called from aidevops context

**Options to evaluate:**
1. **Merge fully** - Combine into aidevops.md with expanded subagent folders
2. **Keep separate but link better** - Improve cross-references, keep modularity
3. **Hybrid** - Move build-agent into aidevops/, keep build-mcp separate (MCP is more specialized)

**Key considerations:**
- Token efficiency: Fewer main agents = less context switching
- Modularity: build-mcp has specialized TypeScript/Bun stack knowledge
- User mental model: Are these distinct domains or one "framework development" domain?
- Progressive disclosure: Current structure already uses subagent pattern

#### Progress

- [ ] (2025-12-21) Phase 1: Analyze usage patterns and cross-references ~1h
- [ ] (2025-12-21) Phase 2: Design merged/improved structure ~1.5h
- [ ] (2025-12-21) Phase 3: Implement chosen approach and test ~1.5h

<!--TOON:milestones[3]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m009,p003,Phase 1: Analyze usage patterns and cross-references,1h,,2025-12-21T14:00Z,,pending
m010,p003,Phase 2: Design merged/improved structure,1.5h,,2025-12-21T14:00Z,,pending
m011,p003,Phase 3: Implement chosen approach and test,1.5h,,2025-12-21T14:00Z,,pending
-->

#### Decision Log

(To be populated during analysis)

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

<!--TOON:active_plans[3]{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p001,aidevops-opencode Plugin,planning,0,4,,opencode|plugin,2d,1d,0.5d,0.5d,2025-12-21T01:50Z,
p002,Claude Code Destructive Command Hooks,planning,0,4,,claude|git|security,4h,2h,1h,1h,2025-12-21T12:00Z,
p003,Evaluate Merging build-agent and build-mcp into aidevops,planning,0,3,,architecture|agents,4h,2h,1h,1h,2025-12-21T14:00Z,
-->

## Completed Plans

<!-- Move completed plans here with Outcomes & Retrospective filled in -->

<!--TOON:completed_plans[0]{id,title,owner,tags,est,actual,logged,started,completed,lead_time_days}:
-->

## Archived Plans

<!-- Plans that were abandoned or superseded -->

<!--TOON:archived_plans[0]{id,title,reason,logged,archived}:
-->

---

## Plan Template

Copy this template when creating a new plan:

```markdown
### [YYYY-MM-DD] Plan Title

**Status:** Planning
**Owner:** @username
**Tags:** #tag1 #tag2
**Estimate:** ~Xd (ai:Xd test:Xd read:Xd)
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md)
**Tasks:** [todo/tasks/tasks-{slug}.md](tasks/tasks-{slug}.md)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p00X,Plan Title,planning,0,N,username,tag1|tag2,Xd,Xd,Xd,Xd,YYYY-MM-DDTHH:MMZ,
-->

#### Purpose

Brief description of why this work matters and what problem it solves.

#### Progress

- [ ] (YYYY-MM-DD HH:MMZ) Phase 1: Description ~Xh
- [ ] (YYYY-MM-DD HH:MMZ) Phase 2: Description ~Xh

<!--TOON:milestones[N]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m001,p00X,Phase 1: Description,Xh,,YYYY-MM-DDTHH:MMZ,,pending
-->

#### Decision Log

- **Decision:** What was decided
  **Rationale:** Why this choice was made
  **Date:** YYYY-MM-DD
  **Impact:** Effect on timeline/scope

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

- **Observation:** What was unexpected
  **Evidence:** How we know this
  **Impact:** How it affects the plan

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

#### Time Tracking

| Phase | Estimated | Actual | Variance |
|-------|-----------|--------|----------|
| Phase 1 | Xh | - | - |
| Phase 2 | Xh | - | - |
| **Total** | **Xh** | **-** | **-** |

<!--TOON:time_tracking{plan_id,total_est,total_actual,variance_pct}:
p00X,Xh,,
-->
```

### Completing a Plan

When a plan is complete, add this section and move to Completed Plans:

```markdown
#### Outcomes & Retrospective

**What was delivered:**
- Deliverable 1
- Deliverable 2

**What went well:**
- Success 1
- Success 2

**What could improve:**
- Learning 1
- Learning 2

**Time Summary:**
- Estimated: Xd
- Actual: Xd
- Variance: ±X%
- Lead time: X days (logged to completed)

<!--TOON:retrospective{plan_id,delivered,went_well,improve,est,actual,variance_pct,lead_time_days}:
p00X,Deliverable 1; Deliverable 2,Success 1; Success 2,Learning 1; Learning 2,Xd,Xd,X,X
-->
```

---

## Analytics

<!--TOON:analytics{total_plans,active,completed,archived,avg_lead_time_days,avg_variance_pct}:
3,3,0,0,,
-->
