<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2866: P2a — `_inbox/` directory contract + per-repo provisioning

## Pre-flight

- [x] Memory recall: "knowledge plane provisioning directory contract" — surfaced t2842 P0a pattern; mirror that
- [x] Discovery pass: `inbox-helper.sh` does not exist; no in-flight PRs touching `_inbox/`
- [x] File refs verified: pattern source `t2842-brief.md` for P0a (knowledge plane contract)
- [x] Tier: `tier:standard` — directory contract + provisioning script, mechanical work modeled on P0a

## Origin

- **Created:** 2026-04-25
- **Session:** Claude Code interactive session (t2840 decomposition follow-up)
- **Created by:** ai-interactive
- **Parent task:** t2840 / GH#20892 (knowledge planes MVP)
- **Conversation context:** During architecture review user identified that planes-without-inbox is unusable at capture velocity. GTD/PARA convergence on inbox-as-foundational holds. Triage requires sensitivity layer (P0.5a/P0.5c) so this phase blocks on those for the routine path; the directory contract + capture CLI ship without dependency.

## What

Establishes `_inbox/` as a top-level peer to the planes — visible in any aidevops-managed repo, treated as a transit zone rather than authoritative storage. Provisioning helper creates the structure on `aidevops init` for new repos and on demand for existing repos. Files in `_inbox/` are by-default `unverified` for sensitivity until triage classifies them.

After completion:

- `aidevops init` provisions `_inbox/` with sub-folders.
- `aidevops inbox provision` adds it to existing repos idempotently.
- The directory has a `README.md` documenting the transit-zone semantics.
- Workspace-level (cross-repo) inbox at `~/.aidevops/.agent-workspace/inbox/` provisioned on first install.

## Why

Without an inbox, every capture requires upfront classification (which plane? which sub-folder? what sensitivity?). That kills capture rate and adoption. Inbox is the foundational pattern that makes the other planes usable in practice.

The directory contract also establishes the sensitivity guarantee: nothing in `_inbox/` may flow to cloud LLMs until P2c triage classifies it. This is enforced contractually (LLM routing helper from P0.5b checks plane membership; `_inbox/` membership = local-only).

## Tier

**Selected tier:** `tier:standard`. Single-helper-file work modeled directly on the P0a knowledge plane contract pattern. Not in `.agents/configs/self-hosting-files.conf` — touches new framework helper, not dispatch path.

## PR Conventions

Child of parent-task t2840 (GH#20892). Use `For #20892` (NEVER `Closes`/`Resolves`) — parent stays open until final phase child PR (typically P6b) closes it.

## How

### Files to Modify

- `NEW: .agents/scripts/inbox-helper.sh` — provisioning + future triage entry point. Model on `.agents/scripts/knowledge-helper.sh` shape (from t2843/P0b once landed; otherwise model on `worktree-helper.sh` for the multi-subcommand pattern with `cmd_<name>` functions).
- `NEW: .agents/templates/inbox-readme.md` — explains transit-zone semantics, written into `_inbox/README.md` on provision.
- `EDIT: .agents/scripts/aidevops` — register `inbox` subcommand (delegate to `inbox-helper.sh`).
- `EDIT: setup.sh` — call `inbox-helper.sh provision-workspace` on install for the cross-repo inbox at `~/.aidevops/.agent-workspace/inbox/`.

### Implementation Steps

1. Read the equivalent P0a knowledge plane contract once t2842 brief is committed; mirror the same shape (provision, validate, list, status subcommands).
2. Implement `inbox-helper.sh provision <repo-path>`:
   - Creates `_inbox/{_drop,email,web,scan,voice,import,_needs-review}/`
   - Writes `_inbox/README.md` from the template
   - Writes `_inbox/.gitignore` excluding everything except `README.md` and `triage.log` (binary captures shouldn't pollute git)
   - Writes empty `_inbox/triage.log` (JSONL append target)
   - Idempotent: existing dirs untouched, missing dirs created
3. Implement `inbox-helper.sh provision-workspace`:
   - Same structure under `~/.aidevops/.agent-workspace/inbox/`
   - For captures not tied to a specific repo (personal capture)
4. Implement `inbox-helper.sh status <repo-path>`:
   - Reports counts per sub-folder (drop=N email=N web=N etc.)
   - Reports oldest item age (for stale detection — feeds P2d)
5. Hook into `aidevops` CLI: `aidevops inbox <subcommand>` delegates to helper.
6. Wire into `setup.sh` for workspace inbox auto-provision.
7. Add a smoke test `.agents/scripts/test-inbox-provision.sh` modeled on existing `test-pulse-cleanup-config-defaults.sh`.

### Complexity Impact

- **Target function:** none (new file)
- **New file size estimate:** ~150-200 lines
- **Action required:** None — well within file-size and function-complexity gates.

### Verification

```bash
shellcheck .agents/scripts/inbox-helper.sh
.agents/scripts/test-inbox-provision.sh
# Provision in a sandbox repo, verify structure exists
.agents/scripts/inbox-helper.sh provision /tmp/test-repo
test -d /tmp/test-repo/_inbox/_drop
test -f /tmp/test-repo/_inbox/README.md
test -f /tmp/test-repo/_inbox/.gitignore
test -f /tmp/test-repo/_inbox/triage.log
```

### Files Scope

- `.agents/scripts/inbox-helper.sh`
- `.agents/templates/inbox-readme.md`
- `.agents/scripts/aidevops`
- `setup.sh`
- `.agents/scripts/test-inbox-provision.sh`

## Acceptance Criteria

- [ ] `aidevops inbox provision <repo>` creates the full directory contract idempotently.
- [ ] Workspace inbox provisioned at `~/.aidevops/.agent-workspace/inbox/` on `setup.sh` run.
- [ ] `_inbox/.gitignore` excludes binaries (sub-folder contents) but keeps `README.md` + `triage.log`.
- [ ] `aidevops inbox status` reports counts and oldest-item age.
- [ ] `shellcheck` clean.
- [ ] Smoke test `test-inbox-provision.sh` PASSes.

## Context & Decisions

- **Why top-level peer to planes:** Visibility — users must see the inbox to use it. Hiding it under `~/.aidevops/.agent-workspace/` defeats the capture-friction goal.
- **Why per-repo + workspace-level:** Per-repo inbox honours the repo's sensitivity baseline (privileged-case repo's inbox is privileged-by-default). Workspace inbox catches captures not tied to a specific repo.
- **Why `triage.log` is committed:** Audit trail for routing decisions — if triage routed wrongly, user can reconstruct what happened. Binary captures stay gitignored (size + sensitivity).
- **Blocked-by None:** This phase ships independently of P0.5 because the directory contract is purely structural. Triage logic (P2c) is what blocks on P0.5.

## Relevant Files

- `.agents/scripts/knowledge-helper.sh` (will exist after t2843/P0b lands) — primary reference pattern
- `.agents/scripts/worktree-helper.sh` — multi-subcommand `cmd_<name>` pattern
- `setup.sh` — provisioning hook point
- `t2842-brief.md` once committed — exact P0a pattern for plane provisioning

## Dependencies

- **Blocked by:** none (can ship in parallel with P0a)
- **Blocks:** P2b (capture CLI uses this directory contract), P2c (triage uses these sub-folders)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | re-read P0a brief and helper pattern |
| Implementation | 2h | helper script + template + CLI wire-up + setup.sh hook |
| Testing | 1h | smoke test + shellcheck |
| **Total** | **~3.5h** | |
