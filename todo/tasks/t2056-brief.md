<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2056: Phase 1 — interactive-session-helper.sh foundation + AI-guidance prompt rule

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Parent task:** t2055 / GH#18738
- **Conversation context:** Phase 1 of the interactive-session auto-claim feature. Ships the helper script and the system-prompt rule that makes the AI responsible for calling `claim`/`release` from conversation intent. Nothing becomes code-mandatory in this phase — Phase 2 (t2057) adds the wiring.

## What

Ship the interactive-session-helper.sh script and the `prompts/build.txt` rule that drives it, without yet wiring it into `worktree-helper.sh` / `claim-task-id.sh` / `approval-helper.sh`. The helper is the foundation that Phase 2 will call; the prompt rule is the enforcement layer that makes the mechanism "mandatory and unavoidable" via the always-loaded system prompt rather than via code interception.

## Why

Shipping this phase alone is safe:

- The new helper script is purely additive (no existing code calls it yet).
- The prompt rule loads into every future interactive session and tells the agent to call the helper from conversation intent — so the mechanism starts working immediately after merge, even before Phase 2's code wiring lands.
- If there's a bug in the helper, the failure mode is "claim fails, agent continues with a warning" — no existing workflow breaks because no existing workflow depends on the helper yet.

Phase 1 is also where the agent contract is established. The rule is what makes future interactive sessions do the right thing by default; Phase 2 is the code-level safety net for paths the agent might miss.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** No — 4 files (2 new, 2 edited). Justifies standard tier.
- [x] **Complete code blocks for every edit?** Yes for helper and test; prompt-rule text is verbatim below.
- [ ] **No judgment or design decisions?** Prompt rule wording matters. Editorial judgement required.
- [x] **No error handling or fallback logic to design?** Helper has one fallback (offline warn-and-continue) — specified below.
- [x] **Estimate 1h or less?** ~45 minutes.
- [x] **4 or fewer acceptance criteria?** 5 — one over, justified by scope.

**Selected tier:** `tier:standard` — prompt rule composition warrants Sonnet's editorial attention. Haiku's strict copy-paste bar is too tight for the rule drafting.

## How (Approach)

### Files to modify

- **NEW:** `.agents/scripts/interactive-session-helper.sh` (~180 lines)
- **NEW:** `.agents/scripts/tests/test-interactive-session-claim.sh` (~120 lines)
- **EDIT:** `.agents/prompts/build.txt` — add `Interactive issue ownership (MANDATORY — AI-driven)` rule under Git Workflow section
- **EDIT:** `.agents/AGENTS.md` — document the auto-claim behaviour in Git Workflow, cross-reference helper and rule

### `interactive-session-helper.sh` contract

```text
Usage:
  interactive-session-helper.sh claim <issue> <slug> [--worktree PATH]
  interactive-session-helper.sh release <issue> <slug> [--unassign]
  interactive-session-helper.sh status [<issue>]
  interactive-session-helper.sh scan-stale
  interactive-session-helper.sh help

claim <issue> <slug>
    Apply status:in-review, self-assign current gh user, write crash-recovery
    stamp to ~/.aidevops/.agent-workspace/interactive-claims/<slug-flat>-<issue>.json.
    Idempotent — re-running refreshes the stamp timestamp but does not re-transition.
    Offline gh: print one-line warning, exit 0.

release <issue> <slug> [--unassign]
    Transition status:in-review -> status:available, delete stamp.
    --unassign also removes self from assignees.
    Idempotent — no-op when label is not set.

status [<issue>]
    Print active claims from stamp directory. With <issue>: check one claim,
    exit 0 if claimed by this user, 1 otherwise.

scan-stale
    For each stamp: check if PID is alive AND worktree path still exists.
    Print a human-readable advisory listing stale claims. Does NOT auto-release —
    the AI is expected to parse the output and prompt the user.

help
    Print usage.
```

Stamp file JSON schema:

```json
{
  "issue": 18738,
  "slug": "marcusquinn/aidevops",
  "worktree_path": "/Users/marcusquinn/Git/aidevops-feature-t2055-interactive-session-claim",
  "claimed_at": "2026-04-13T22:30:00Z",
  "pid": 12345,
  "hostname": "mbp-marcusquinn"
}
```

### `prompts/build.txt` rule (verbatim starting text)

Add under the `# Git Workflow` section, before the existing "Origin labelling" entry:

```markdown
# Interactive issue ownership (MANDATORY — AI-driven)
# When an interactive session engages with a GitHub issue — by opening a
# worktree for it, claiming a new task, or because the user identifies an
# existing issue to work on ("let me fix #18700", "what's going on with this
# one", pasted issue URL, PR or issue view) — you MUST immediately call
# `interactive-session-helper.sh claim <N> <slug>`. This applies
# `status:in-review`, self-assigns the current gh user, and writes a
# crash-recovery stamp. The pulse's dispatch-dedup guard already treats
# `status:in-review` as an active claim — no worker will be dispatched while
# the label is set.
- Release is the AI's responsibility, not the user's. When the user signals
  completion ("ship it", "I'm done", "moving on", "let a worker take over"),
  when they switch to a different issue, or when a PR they opened merges,
  call `interactive-session-helper.sh release <N> <slug>`. Never make the
  user type a release command.
- On interactive session start, run `interactive-session-helper.sh scan-stale`
  and prompt the user to release any claims whose PID is dead and worktree
  path is missing. Act on confirmation.
- On offline `gh`: the helper prints a warning and exits 0. Continue with the
  session — a collision with a worker is harmless and the interactive work
  naturally becomes its own issue/PR.
- The slash command `/release-issue <N>` and the CLI `aidevops issue release
  <N>` exist as fallbacks but should never be the primary path — you detect
  intent and act.
```

### `.agents/AGENTS.md` addition

Under `## Git Workflow`, after the "Origin labelling (MANDATORY)" block, add:

```markdown
**Interactive issue ownership (MANDATORY — AI-driven):**
- Whenever an interactive session engages with a GitHub issue, the agent MUST
  call `interactive-session-helper.sh claim <N> <slug>`. This applies
  `status:in-review` + self-assignment, which the pulse's dispatch-dedup guard
  already honours — no worker will be dispatched while the label is set.
- Release is also the agent's responsibility, triggered by conversation
  signals ("done", "moving on", "let a worker take over") or by a merge that
  closes the linked issue. The user should never need to type a release
  command.
- Session start runs `interactive-session-helper.sh scan-stale` and surfaces
  dead claims (PID gone, worktree missing) as an advisory.
- Offline `gh`: warn and continue. Collision with a worker is harmless.
- Full rule in `prompts/build.txt` → "Interactive issue ownership".
```

### Verification

```bash
# 1. Shellcheck clean on helper and test
shellcheck .agents/scripts/interactive-session-helper.sh
shellcheck .agents/scripts/tests/test-interactive-session-claim.sh

# 2. Test harness passes
bash .agents/scripts/tests/test-interactive-session-claim.sh

# 3. Manual smoke test
./.agents/scripts/interactive-session-helper.sh claim 18738 marcusquinn/aidevops
gh issue view 18738 --repo marcusquinn/aidevops --json labels,assignees
./.agents/scripts/interactive-session-helper.sh status 18738
./.agents/scripts/interactive-session-helper.sh release 18738 marcusquinn/aidevops
gh issue view 18738 --repo marcusquinn/aidevops --json labels,assignees

# 4. Markdown lint on edited prose files
markdownlint-cli2 .agents/prompts/build.txt .agents/AGENTS.md
```

## Acceptance Criteria

- [ ] `interactive-session-helper.sh` exists, shellcheck clean, exposes `claim`, `release`, `status`, `scan-stale`, `help`
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/interactive-session-helper.sh && .agents/scripts/interactive-session-helper.sh help"
  ```
- [ ] `test-interactive-session-claim.sh` passes with at least 5 assertions (claim idempotency, release idempotency, stamp create/delete, offline warn-and-continue, scan-stale dead-PID detection)
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-interactive-session-claim.sh"
  ```
- [ ] `prompts/build.txt` contains "Interactive issue ownership (MANDATORY — AI-driven)" rule
  ```yaml
  verify:
    method: codebase
    pattern: "Interactive issue ownership.*MANDATORY.*AI-driven"
    path: ".agents/prompts/build.txt"
  ```
- [ ] `AGENTS.md` Git Workflow section documents the auto-claim behaviour
  ```yaml
  verify:
    method: codebase
    pattern: "interactive-session-helper.sh claim"
    path: ".agents/AGENTS.md"
  ```
- [ ] Markdown lint clean on `build.txt` and `AGENTS.md`
  ```yaml
  verify:
    method: bash
    run: "markdownlint-cli2 .agents/prompts/build.txt .agents/AGENTS.md"
  ```

## Context & Decisions

- **Why helper as a shell script and not inline function in shared-constants.sh?** Because it's a command-line primitive the agent calls directly from conversation. Shell script → direct `bash` invocation, subcommand dispatch, standalone test harness. Inline function would require every caller to source shared-constants.sh which adds coupling.
- **Why stamp directory at `~/.aidevops/.agent-workspace/interactive-claims/`?** Matches the existing workspace convention in `prompts/build.txt` ("Working Directories" section). Persistent across sessions but per-user, per-machine.
- **Why warn-and-continue on offline instead of fail-closed?** User explicitly directed this. A collision with a pulse worker is harmless — the interactive work becomes its own issue/PR. Fail-closed would defend against a non-problem and add friction.
- **Why scan-stale doesn't auto-release?** The AI should prompt the user before releasing something. Auto-release risks losing a claim that was still intentional (e.g., session on another machine). The helper surfaces information; the agent decides.
- **Non-goals:**
  - Wiring into worktree-helper/claim-task-id/approval-helper (Phase 2)
  - Any dispatch-dedup logic (already handles in-review)
  - Any new label
  - Any slash-command or CLI plumbing (fallbacks, not primary)

## Relevant Files

- `.agents/scripts/shared-constants.sh:1054` — `set_issue_status` is the label-transition primitive the helper wraps
- `.agents/scripts/dispatch-dedup-helper.sh:957` — `_has_active_claim` already gates on `status:in-review`
- `.agents/scripts/claim-task-id.sh:607` — `_auto_assign_issue` is the pattern the helper's self-assign mirrors
- `.agents/prompts/build.txt` — target file for the prompt rule
- `.agents/AGENTS.md` — target file for the doc update

## Dependencies

- **Blocked by:** none
- **Blocks:** Phase 2 (t2057 / GH#18740) — Phase 2 imports the helper
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Helper implementation | 15m | ~180 lines, subcommand dispatch |
| Test harness | 10m | 5+ assertions, PATH stub for offline |
| Prompt rule + AGENTS.md | 10m | Verbatim draft adapted to section voice |
| Verification + lint | 5m | shellcheck, markdownlint, manual smoke |
| Commit + PR | 5m | Conventional commit, PR body |
| **Total** | **~45m** | |
