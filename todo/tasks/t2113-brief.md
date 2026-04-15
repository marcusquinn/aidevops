<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2113: feat(ci): systemic gh_create_issue / gh_create_pr wrapper enforcement

## Origin

- **Created:** 2026-04-15
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (same awardsapp investigation as t2112)
- **Parent task:** none
- **Conversation context:** The wrapper-use rule in `prompts/build.txt` → "Origin labelling (MANDATORY)" is advisory. It relies on the model reading and following a system prompt rule. Discovery for t2112 found that six awardsapp issues were created with bare `gh issue create`, bypassing the wrapper and arriving unlabelled. Inside the framework itself, an `rg 'gh issue create' .agents/scripts/` found multiple ad-hoc usages that weren't migrated when `gh_create_issue` was introduced. The operator asked for this to move from advisory to systemic — a CI gate plus an optional local pre-push hook so the rule is enforced at push time instead of discovered later via unlabelled issues in production repos.

## What

Two enforcement points for the `gh_create_issue` / `gh_create_pr` wrapper rule:

1. **CI workflow** — `.github/workflows/gh-wrapper-guard.yml` runs on PRs that touch `.agents/scripts/**.sh`. It invokes `.agents/scripts/gh-wrapper-guard.sh check --base origin/main` which:
   - Scans the PR's added/modified shell script lines for raw `gh issue create` or `gh pr create` calls.
   - Excludes: `shared-constants.sh` (definition site), `github-cli-helper.sh` if it defines fallbacks, comment lines, lines inside heredocs that are clearly docs, and test fixture files under `.agents/scripts/tests/`.
   - Excludes files that legitimately call raw `gh pr create` / `gh issue create` and are audited (maintained allowlist via a `# aidevops-allow: raw-gh-wrapper` end-of-line marker).
   - Fails the check with a PR comment listing offending lines and a link to `prompts/build.txt` "Origin labelling".
2. **Local pre-push hook** — `.agents/hooks/gh-wrapper-guard-pre-push.sh`, installable via the existing `install-hooks-helper.sh` pattern. Runs the same `gh-wrapper-guard.sh check` on the commit range being pushed. Bypass: `GH_WRAPPER_GUARD_DISABLE=1 git push …` or `git push --no-verify` (mirrors the privacy guard bypass flags).

Scope: rule applies to `.agents/scripts/**.sh` ONLY. `gh` commands in `.github/workflows/*.yml` are out of scope (they run in GitHub Actions context where the wrapper isn't available). Docs (`*.md`) are out of scope — they may legitimately show `gh issue create` in examples.

## Why

`gh_create_issue` / `gh_create_pr` wrappers in `shared-constants.sh` apply `session_origin_label` + auto-assign + (for issues) sub-issue linking via `_gh_auto_link_sub_issue`. Skipping them produces unlabelled, unassigned, unlinked issues and PRs that the maintainer gate rejects, the dedup system can't see, and the pulse can't reconcile until t2112 ships.

The rule exists in `prompts/build.txt` but soft rules on a 1700-line system prompt do not reliably propagate to every session. The framework has been through at least 13+ scripts' worth of migration to these wrappers already (see commit `b284abe8b` comment: "13+ scripts that use `gh_create_issue` directly"). A static check is cheap to run (one `git diff | grep`) and catches the regression at PR time instead of "six weeks later when someone notices".

Pre-push hook is optional and opt-in: the CI gate is the authoritative enforcement, the hook is a local shortcut to avoid a CI round-trip.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify — **false**, 4 new files (guard script + workflow + pre-push hook + test harness)
- [x] Every target file under 500 lines — true
- [x] No judgment calls — regex + allowlist marker
- [x] Estimate 1h or less — true
- [x] 4 or fewer acceptance criteria — **false**, 5 below

**Selected tier:** `tier:standard` — mechanical CI + hook scaffolding modelled on the existing `qlty-new-file-gate-helper.sh` + `qlty-new-file-gate.yml` pair.

## PR Conventions

Leaf task. PR body uses `Resolves #NNN`.

## How (Approach)

### Files to Modify

- NEW: `.agents/scripts/gh-wrapper-guard.sh` — standalone checker supporting `check [--base REF]` (CI diff check), `check-staged` (local pre-commit), and `check-full` (full-tree audit). Bash 3.2 compatible, uses `git diff --name-only` + `git diff -U0` for the line-level scan.
- NEW: `.github/workflows/gh-wrapper-guard.yml` — runs on PRs touching `.agents/scripts/**.sh`, invokes `check --base origin/main`, fails on non-zero exit, posts a PR comment with the offending lines on failure.
- NEW: `.agents/hooks/gh-wrapper-guard-pre-push.sh` — pre-push hook that invokes `check --base $upstream_sha`; respects `GH_WRAPPER_GUARD_DISABLE=1`.
- NEW: `.agents/scripts/tests/test-gh-wrapper-guard.sh` — fixture-based test with a temp git repo, stages offending + allowed + allowlisted lines, asserts exit codes.
- EDIT: `.agents/scripts/install-hooks-helper.sh` — add `gh-wrapper-guard` to the installable hook list alongside `privacy-guard` and `git_safety_guard`.

### Implementation Steps

**Step 1 — write `gh-wrapper-guard.sh`.** Subcommands:

- `check [--base REF]` — `git diff --name-only REF...HEAD -- '.agents/scripts/*.sh' '.agents/hooks/*.sh'` to list candidate files. For each file, `git diff -U0 REF...HEAD -- "$file"` and scan added lines (`^+[^+]`) for the forbidden pattern.
- `check-staged` — same logic but against staged files (`git diff --cached`).
- `check-full` — `grep -rn` the whole tree for full audit (used by a one-shot migration sweep).
- Forbidden pattern: `^\+.*[^_a-zA-Z]gh\s+(issue|pr)\s+create\b` — the negative look-before excludes `gh_create_issue` / `gh_create_pr` (underscore between `h` and `create`).
- Allowlist marker: any line ending in `# aidevops-allow: raw-gh-wrapper` is accepted. Line-level allowlist keeps the escape valve narrow and self-documenting.
- File-level exclusions: `.agents/scripts/shared-constants.sh` (definition site), any path matching `.agents/scripts/tests/` (test fixtures may legitimately shell out to raw `gh`).
- Exit 0 = clean, exit 1 = violations found (prints `file:line: raw `gh issue create` — use gh_create_issue wrapper` per violation).

**Step 2 — CI workflow.** Model on `.github/workflows/qlty-new-file-gate.yml`:

- Trigger: `pull_request` with `paths: - '.agents/scripts/**.sh' - '.agents/hooks/**.sh'`.
- Steps: checkout with `fetch-depth: 0`, then `bash .agents/scripts/gh-wrapper-guard.sh check --base "origin/${{ github.base_ref }}"`.
- On failure, post a PR comment listing offending lines and linking to `prompts/build.txt` "Origin labelling".

**Step 3 — pre-push hook.** `.agents/hooks/gh-wrapper-guard-pre-push.sh` reads stdin (ref updates) and runs `gh-wrapper-guard.sh check --base <remote_sha>` for each. Respects `GH_WRAPPER_GUARD_DISABLE=1`.

**Step 4 — hook registration.** Add to `install-hooks-helper.sh install` list. Reuse the existing idempotent install loop.

**Step 5 — test harness.** Temp git repo, stage offending and allowlisted lines, run `gh-wrapper-guard.sh check --base HEAD~1`, assert exit code and stdout contents.

### Verification

```bash
cd /Users/marcusquinn/Git/aidevops-feature-t2112-pulse-labelless-reconcile-gh-wrapper-sub-issue-body
shellcheck .agents/scripts/gh-wrapper-guard.sh .agents/hooks/gh-wrapper-guard-pre-push.sh
bash .agents/scripts/tests/test-gh-wrapper-guard.sh
bash .agents/scripts/gh-wrapper-guard.sh check-full  # baseline full-tree audit
```

The `check-full` baseline audit is expected to find some in-tree offenders — file a follow-up task to migrate them, do not block this PR on cleanup.

## Acceptance Criteria

1. `gh-wrapper-guard.sh` exists and supports `check`, `check-staged`, `check-full` subcommands.
2. Raw `gh issue create` / `gh pr create` in a new/modified `.agents/scripts/**.sh` line triggers a check failure.
3. Lines ending in `# aidevops-allow: raw-gh-wrapper` are accepted.
4. CI workflow `.github/workflows/gh-wrapper-guard.yml` runs on matching PR paths and fails on violations.
5. Pre-push hook is installable via `install-hooks-helper.sh install` and respects `GH_WRAPPER_GUARD_DISABLE=1`.
6. Test harness covers offending / allowed / allowlisted / excluded cases and exits 0.
7. Shellcheck clean on all new shell scripts.
