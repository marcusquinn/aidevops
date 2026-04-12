<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2009: dispatch hardening — cross-runner coordination reference doc

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** Tier C systemic fix from the GH#18356 root-cause analysis
- **Conversation context:** During this session, two pulse runners (`marcusquinn` and `alex-solovyev`) raced repeatedly on issues. The race patterns are documented in scattered places (PR bodies, AGENTS.md, GH#18352, t1986 brief) but no single doc explains the multi-runner mental model: who locks what, who can override what, when the runners coordinate vs when they don't, what failure modes to expect, and what the maintainer should configure on each machine.

## What

Create `.agents/reference/cross-runner-coordination.md` documenting how aidevops handles multiple concurrent pulse runners. Audience: a maintainer who is bringing up a new runner machine, or debugging a multi-runner race.

The doc covers:

1. **Mental model** — what a "runner" is, how runners discover each other (they don't directly — coordination is via GitHub issues/labels/comments), what the cross-runner contract is.
2. **Coordination signals** (what each runner reads/writes):
   - Issue assignees
   - Status labels (`status:queued`, `status:in-progress`, `status:in-review`, `status:claimed`)
   - Origin labels (`origin:interactive`, `origin:worker`)
   - Dispatch comments (`DISPATCH_CLAIM nonce=...`, `<!-- ops:start -->` blocks)
   - Issue locks
3. **Race scenarios observed in this session** — at least:
   - GH#18356 parent-task race (resolved by t1986)
   - GH#18367 interactive-claim race (resolved by t1970)
   - Stale recovery loop (resolved by t2008)
   - Token cost runaway (resolved by t2007)
4. **The dedup layer chain** in `dispatch-dedup-helper.sh` — what each layer guards against, in order. Cross-reference the existing `pulse-dispatch-core.sh` "Layers 1-7" comments.
5. **Per-runner setup** — what a maintainer brings up on a new machine: install, auth, repo registration, pulse launchd, version sync requirements (the alex-solovyev incident this session was caused by version skew — the runner's pulse predated the GH#18352 fix).
6. **Failure mode catalogue** — how to recognise each, how to recover, where to look for evidence (logs, comments, labels).
7. **The setup of `~/.config/aidevops/repos.json` `pulse: true`** and the implications of dispatching to issues outside `PULSE_SCOPE_REPOS`.

## Why

- **The runner contract is currently tribal knowledge.** Bits are in AGENTS.md, bits are in PR bodies (GH#18352, t1970), bits are in the dispatch-dedup-helper.sh source comments, bits are in t1986's brief and PR description. A new operator has no single entry point.
- **Race patterns are repeatable.** Documenting them once means future investigation skips the rediscovery phase.
- **Multi-runner is the framework's growth direction** — more contributors means more runners. The cost of NOT documenting this scales.
- **t1986 documented the parent-task guard inline in AGENTS.md but is one paragraph.** A reference doc gives room for the full mental model.

## Tier

`tier:standard`. This is documentation work — no code, no risk. The challenge is research (gathering scattered knowledge into one place) and clarity, not technical complexity.

### Tier checklist

- [x] **2 or fewer files to modify?** — 1 new file + 2 small cross-reference additions to AGENTS.md
- [x] **Complete code blocks for every edit?** — N/A, this is prose
- [x] **No judgment or design decisions?** — moderate (what to include, what to defer to source comments)
- [x] **No error handling or fallback logic to design?** — N/A
- [ ] **Estimate 1h or less?** — estimated 2-3h
- [x] **4 or fewer acceptance criteria?** — 4 below

5/6 → leans simple but the research surface is broad. `tier:standard` is right.

## How

### Files to create / modify

- **NEW:** `.agents/reference/cross-runner-coordination.md` — the main doc
- **EDIT:** `.agents/AGENTS.md` — add a one-liner pointer in the "Cross-Repo Task Management" section: *"For multi-runner coordination, see `reference/cross-runner-coordination.md`."*
- **EDIT:** `.agents/reference/worker-diagnostics.md` (if exists) — add a "see also" reference

### Research checklist (worker should do this BEFORE writing prose)

```bash
# 1. Source-of-truth files
rg -n "cross-runner|cross-machine|multi-runner|alex-solovyev|self_login" .agents/scripts/dispatch-dedup-helper.sh .agents/scripts/pulse-dispatch-core.sh .agents/AGENTS.md

# 2. PR descriptions for the relevant fixes
gh pr view 18352 --repo marcusquinn/aidevops  # GH#18352 cross-runner assignee guard
gh pr view 18374 --repo marcusquinn/aidevops  # t1970 interactive-claim race fix
gh pr view 18419 --repo marcusquinn/aidevops  # t1986 parent-task guard

# 3. Issue threads with the race incidents
gh issue view 18356 --repo marcusquinn/aidevops --comments  # the parent-task incident (t1962 Phase 3)
gh issue view 18367 --repo marcusquinn/aidevops --comments  # the t1967 interactive-claim race
gh issue view 18399 --repo marcusquinn/aidevops --comments  # the t1986 self-fulfilling race

# 4. The 7-layer dedup chain
grep -A2 "Layer [0-9]" .agents/scripts/pulse-dispatch-core.sh

# 5. Existing reference docs that should be linked from the new one
ls .agents/reference/ | grep -E "dispatch|worker|pulse|session"
```

### Doc structure (recommended)

```markdown
# Cross-Runner Coordination

> Audience: maintainers operating multiple pulse runners; engineers debugging
> race conditions across machines.

## 1. The runner model

What a runner is (...)
How runners discover each other (they don't, except via GitHub state)
The cross-runner contract: GitHub is the source of truth.

## 2. Coordination signals

### 2.1 Assignees
### 2.2 Status labels
### 2.3 Origin labels
### 2.4 Dispatch comments
### 2.5 Issue locks
### 2.6 Parent-task label (t1986)

## 3. The dedup layer chain

[Layers 1-7 in dispatch order, with the GH issue that motivated each layer]

## 4. Race scenarios and resolutions

### 4.1 The parent-task dispatch loop (GH#18356, fixed by t1986)
### 4.2 The interactive-claim race (GH#18367, fixed by t1970)
### 4.3 Stale-recovery loops (fixed by t2008)
### 4.4 Token cost runaway (fixed by t2007)

## 5. New runner setup

Step-by-step for bringing up a new pulse runner on a new machine.

## 6. Diagnosing a suspected race

Symptoms → look for X in Y → likely root cause → fix or escalate.

## 7. See also

- workflows/pulse.md
- reference/worker-diagnostics.md
- AGENTS.md "Session origin labels" section
```

## Acceptance Criteria

- [ ] `.agents/reference/cross-runner-coordination.md` created with all 7 sections populated
- [ ] At least 4 race scenarios documented with timeline + root cause + resolution
- [ ] AGENTS.md cross-references the new doc from at least one section
- [ ] Existing pulse tests still pass (no code changes expected, but verify)

## Relevant Files

- `.agents/scripts/dispatch-dedup-helper.sh` — the implementation that this doc explains
- `.agents/scripts/pulse-dispatch-core.sh:107` — the 7-layer comment block
- `.agents/AGENTS.md` lines 103-107 — existing cross-runner-related paragraphs
- `.agents/reference/worker-diagnostics.md` (if exists) — sibling reference

## Dependencies

- **Blocked by:** none (t1986 is merged, t2007 + t2008 are siblings being filed at the same time — the doc should reference them as in-flight)
- **Related:** t1986, t1970, t2007, t2008 (the four hardening tasks this doc unifies)

## Estimate

~2.5h: 1h research + 1h writing + 30m cross-references and review.

## Out of scope

- Implementation of any new coordination mechanism (this is doc-only)
- Per-runtime setup details (Linux vs macOS launchd vs systemd) — link to existing setup docs
- Cloud-runner / CI-runner patterns (separate concern)
