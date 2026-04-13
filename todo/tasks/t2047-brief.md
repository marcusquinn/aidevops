<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2047: task-id collision guard — reject invented t-IDs in commit subjects

## Origin

- **Created:** 2026-04-13, claude-code:interactive
- **Trigger incident:** during the t2046 lifecycle (filing the parent-task hardening plan), commit `469732b31 chore(build.txt): add Pre-implementation discovery rule (t2046) (#18597)` landed in main with `(t2046)` in its subject — but the canonical t2046 (mine, claimed via `.task-counter` and tracked in `TODO.md` as GH#18599) is a completely different task. The conflicting commit `Resolves #18508`, which has nothing to do with t2046. The author wrote `t2046` in the subject without claiming via `claim-task-id.sh`.
- **Why it matters:** the failure mode is "human or agent invents a t-ID inline because the subject 'feels right'". `claim-task-id.sh` exists specifically to prevent this, but it can only enforce when called. Today nothing rejects the commit if the author skips the claim step. The collision lives forever in `git log` and confuses anyone running `git log --grep="t\d+"` for traceability.

## What

Add a **commit-msg hook** that scans commit subjects and bodies for `t\d+` references and rejects the commit if any referenced t-ID appears to be invented. Plus a **CI check** as belt-and-braces for commits authored outside the hook (web UI, external contributors, hooks bypassed via `--no-verify`).

**Definition of "invented":**

A `t\d+` reference is invented if BOTH:

1. The numeric ID is **greater than** the current value of `.task-counter` on the branch's merge base with `main` (i.e., the ID was never claimed via `claim-task-id.sh`), AND
2. The commit's footer does not include a `Resolves|Closes|Fixes #NNN` line whose linked GitHub issue title contains the same `t\d+` (which would prove the ID was claimed by someone else and the author is correctly cross-referencing).

Both conditions must hold to reject. This permits:

- Cross-referencing OTHER people's claimed t-IDs (e.g. "fixes regression introduced by t2042")
- Citing a t-ID claimed earlier in the same PR branch (the local counter has been bumped)
- Mentioning t-IDs in commit *bodies* for context, as long as no rule above fires

This rejects only the specific failure mode: "subject says (t2046) but t2046 was never claimed by you and is not in any linked issue".

## Why

See "Origin" above for the case study. Plus:

- The existing `claim-task-id.sh` is the only path that atomically allocates a t-ID. Bypassing it produces collisions that are invisible until someone tries to trace work through the t-ID system.
- The collision IS recoverable post-hoc (rebase the offending commit message, push --force) but only if someone notices, which they usually don't.
- The cost of the guard is microseconds at commit time. The cost of a missed collision is ongoing audit-trail confusion forever.

## Tier

`tier:standard`. Mechanical implementation following the existing privacy-guard installer pattern.

### Tier checklist

- [x] **>2 files?** Yes (1 hook, 1 installer, 1 CI workflow, 1 test, 1 doc edit) — disqualifies `tier:simple`.
- [ ] Skeleton code blocks? No — every step has a verbatim source pattern.
- [ ] Error/fallback logic to design? No — fail-safe behavior is explicitly specified below.
- [x] Estimate >1h? Yes (~3-4h) — disqualifies `tier:simple`.
- [ ] >4 acceptance criteria? 7 criteria but each is a single mechanical check.
- [ ] Judgment keywords? No — every rule is concrete.

`tier:standard` is correct.

## How (Approach)

### Files to modify

- **NEW:** `.agents/hooks/task-id-collision-guard.sh` — the commit-msg hook. Reads the commit message file path from `$1` (commit-msg hook contract). Extracts all `t\d+` matches from the subject and body. For each match, applies the §What "invented" detection rules. Exits 0 (allow) or 1 (reject with a clear error explaining how to fix).
- **NEW:** `.agents/scripts/install-task-id-guard.sh` — per-repo installer mirroring `install-privacy-guard.sh`. Subcommands: `install`, `uninstall`, `status`, `test`. Targets the git common dir so worktrees share the hook with the parent repo. Chains into any existing commit-msg hook rather than overwriting.
- **NEW:** `.github/workflows/task-id-collision-check.yml` — runs on `push` and `pull_request` events. Calls `task-id-collision-guard.sh check-pr <PR_NUMBER>` (new subcommand) which scans every commit in the PR range and runs the same logic. Posts a check status. Fails the check on violation.
- **NEW:** `.agents/scripts/tests/test-task-id-collision-guard.sh` — covers all branches of the rejection logic (see Acceptance Criteria for the 7 cases).
- **EDIT:** `.agents/AGENTS.md` "Git Workflow" — one-line note: "Task IDs in commit subjects MUST be claimed via `claim-task-id.sh`. The commit-msg hook (`install-task-id-guard.sh install`) enforces this client-side; the CI check enforces it server-side."
- **EDIT:** `setup.sh` — auto-install the hook as part of the standard setup flow, mirroring how privacy-guard is installed today (if it is — verify first; if not, document the manual install step).

### Reference patterns

- **`.agents/hooks/privacy-guard-pre-push.sh`** — the canonical "guard hook script" model. Same shape: single-purpose, exit 0/1, prints actionable error message on rejection. Read this end-to-end before writing the new hook.
- **`.agents/scripts/install-privacy-guard.sh`** — the canonical "per-repo hook installer" model. Subcommands, chain-into-existing logic, common-dir targeting. Mirror exactly.
- **`.agents/hooks/canonical-on-main-guard.sh`** — second hook example to confirm the conventions.
- **`.agents/scripts/claim-task-id.sh`** — read this to understand `.task-counter` semantics. The hook needs to know how to read the counter and how to compare against arbitrary `t\d+` references.
- **`.github/workflows/framework-validation.yml`** — model for the new GitHub Actions workflow.

### Implementation steps

1. **Read `install-privacy-guard.sh` end-to-end.** The new installer is a near-clone with one swap: `pre-push` → `commit-msg`, and a different deployed-hook path.
2. **Read `privacy-guard-pre-push.sh` end-to-end.** The new hook follows the same shape but with different scanning rules.
3. **Write `task-id-collision-guard.sh`** with two modes:
    - Default mode (no args except `$1`): commit-msg hook contract. Read message from file path in `$1`. Apply rejection rules. Exit 0 or 1.
    - `check-pr <PR_NUMBER>` mode: scans every commit in the PR range via `git log <merge-base>..HEAD --format='%H %s%n%b'`. Used by CI.
4. **Implement the "invented" detection:**
    - Extract `t(\d+)` matches from the message
    - Read `.task-counter` value at the merge base via `git show <merge-base>:.task-counter`
    - For each `t\d+` match: if `numeric_id > merge_base_counter`, flag as suspicious
    - For each suspicious match: scan the commit footer for `(Resolves|Closes|Fixes) #(\d+)` lines, fetch each linked issue's title via `gh issue view --json title`, and check if the title contains the same `t\d+`. If yes → not invented (allow). If no → invented (reject).
    - On `gh` failure (offline, unauthenticated): fail-safe **allow** (don't break offline workflows; CI will catch on push).
5. **Write `install-task-id-guard.sh`** per the privacy-guard installer pattern. Same subcommand structure, same chain-into-existing logic, same common-dir targeting.
6. **Write the test harness** with the 7 cases from Acceptance Criteria.
7. **Add the GitHub Actions workflow.** Use `framework-validation.yml` as the template.
8. **Update `AGENTS.md`** with the one-line note.
9. **Update `setup.sh`** to call `install-task-id-guard.sh install` automatically (verify first that privacy-guard is auto-installed too; mirror the same pattern).
10. **shellcheck everything.**
11. **Eat the dogfood:** the PR's own commits should pass the new check (since this PR's t-ID t2047 IS claimed via `.task-counter`).

### Verification

```bash
# Local
bash .agents/scripts/tests/test-task-id-collision-guard.sh             # all 7 cases pass
shellcheck .agents/hooks/task-id-collision-guard.sh                     # clean
shellcheck .agents/scripts/install-task-id-guard.sh                     # clean

# Synthetic positive case (must reject)
echo "feat(foo): bar (t99999)" > /tmp/synthetic-msg.txt
bash .agents/hooks/task-id-collision-guard.sh /tmp/synthetic-msg.txt
# Expected: exit 1, error "t99999 is not claimed in .task-counter and not cited via Resolves/Closes/Fixes"

# Synthetic negative case (must allow)
echo "feat(foo): bar (t2047)" > /tmp/synthetic-msg.txt
bash .agents/hooks/task-id-collision-guard.sh /tmp/synthetic-msg.txt
# Expected: exit 0

# Cross-reference case (must allow)
printf 'feat(foo): bar — fixes regression from t2042\n\nResolves #18608\n' > /tmp/synthetic-msg.txt
bash .agents/hooks/task-id-collision-guard.sh /tmp/synthetic-msg.txt
# Expected: exit 0 (t2042 is claimed; cross-references are allowed)

# Real installation
bash .agents/scripts/install-task-id-guard.sh install
bash .agents/scripts/install-task-id-guard.sh status
# Expected: hook installed at .git/hooks/commit-msg
```

## Acceptance Criteria

- [ ] `task-id-collision-guard.sh` rejects commits whose subject contains a `t\d+` greater than the merge-base `.task-counter` AND not cross-referenced via a linked issue title
- [ ] Same hook **allows** commits citing claimed t-IDs (≤ counter)
- [ ] Same hook **allows** commits cross-referencing other people's claimed t-IDs
- [ ] Same hook **allows** commits with no `t\d+` references at all
- [ ] Same hook **fails-safe (allow)** on gh API failure or offline state — CI catches on push
- [ ] `install-task-id-guard.sh install` installs into `.git/hooks/commit-msg` and chains into any existing hook
- [ ] `tests/test-task-id-collision-guard.sh` covers all 7 cases (the 5 above plus `--no-verify` bypass and CI `check-pr` mode) and all pass
- [ ] `.github/workflows/task-id-collision-check.yml` runs on push and pull_request events
- [ ] `setup.sh` auto-installs the hook (or documents the manual step explicitly if privacy-guard is also manual today)
- [ ] `AGENTS.md` "Git Workflow" updated with the one-line note
- [ ] ShellCheck clean on all new/modified shell files
- [ ] PR commits dogfood the check — every commit subject in this PR passes the new hook

## Relevant Files

- `.agents/hooks/privacy-guard-pre-push.sh` — model for the new hook script
- `.agents/scripts/install-privacy-guard.sh` — model for the new installer
- `.agents/hooks/canonical-on-main-guard.sh` — second model
- `.agents/scripts/claim-task-id.sh` — `.task-counter` semantics reference
- `.github/workflows/framework-validation.yml` — model for the new CI workflow
- `setup.sh` — gets the auto-install line
- `.agents/AGENTS.md` "Git Workflow" — gets the one-line note

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing
- **Related:**
  - t2046 (parent-task lifecycle hardening, GH#18599) — same case study, sibling hardening task
  - The `claim-task-id.sh` mechanism this complements
  - Privacy-guard hook chain (model architecture)

## Estimate

~3-4h. Mostly clone-and-adapt of `install-privacy-guard.sh` + `privacy-guard-pre-push.sh`, plus the actual scanning logic (which is the only novel part — ~30 lines).

## Out of scope

- Retroactively rewriting commits with collisions already in `git log` (the t2046 collision in commit 469732b31 stays as-is — the hook prevents recurrence, not history)
- Hooks for other invented references (issue numbers, PR numbers — these are harder because they require live GitHub queries on every commit)
- Auto-suggesting the next free t-ID from the hook (just reject — let `claim-task-id.sh` be the only source of allocation)
- Extending to any other ID namespaces (e.g. `r\d+` routine IDs) — file as separate task if needed
